# -*- Mode: Perl; perl-indent-level: 2; indent-tabs-mode: nil -*-
# Copyright 2009 Ge van Geldorp
# Copyright 2012-2017 Francois Gouget
#
# This library is free software; you can redistribute it and/or
# modify it under the terms of the GNU Lesser General Public
# License as published by the Free Software Foundation; either
# version 2.1 of the License, or (at your option) any later version.
#
# This library is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public
# License along with this library; if not, write to the Free Software
# Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1301, USA

use strict;


package WineTestBot::Job;

=head1 NAME

WineTestBot::Job - A job submitted by a user

=head1 DESCRIPTION

A Job is created when a WineTestBot::User asks for something to be tested
(for automatically generated Jobs this would be the batch user). There are many
paths that can result in the creation of a job:

=over

=item *
A use submits a patch or binary to test.

=item *
WineTestBot finds a patch to test on the mailing list (and has all the pieces
it needs for that patch, see WineTestBot::PendingPatchSet).

=item *
WineTestBot notices a Wine commit round and decides to run the full suite of
tests. In this case there is no WineTestBot::Patch object associated with the
Job.

=back

A Job is composed of multiple WineTestBot::Step objects.

=cut

use WineTestBot::Config;
use WineTestBot::Branches;
use WineTestBot::Engine::Notify;
use WineTestBot::WineTestBotObjects;

use vars qw(@ISA @EXPORT);

require Exporter;
@ISA = qw(WineTestBot::WineTestBotItem Exporter);

sub _initialize($$)
{
  my ($self, $Collection) = @_;

  $self->SUPER::_initialize($Collection);

  $self->{OldStatus} = undef;
}

sub InitializeNew($$)
{
  my ($self, $Collection) = @_;

  $self->Archived(!1);
  $self->Branch(CreateBranches()->GetDefaultBranch());
  $self->Status("queued");
  $self->Submitted(time());

  $self->SUPER::InitializeNew($Collection);
}

sub Status($;$)
{
  my ($self, $NewStatus) = @_;

  my $CurrentStatus = $self->SUPER::Status;
  return $CurrentStatus if (!defined $NewStatus);

  if (! defined($CurrentStatus) || $NewStatus ne $CurrentStatus)
  {
    $self->SUPER::Status($NewStatus);
    $self->{OldStatus} = $CurrentStatus;
  }

  return $NewStatus;
}

sub OnSaved($)
{
  my ($self) = @_;

  $self->SUPER::OnSaved();

  if (defined($self->{OldStatus}))
  {
    my $NewStatus = $self->Status;
    if ($NewStatus ne $self->{OldStatus})
    {
      JobStatusChange($self->GetKey(), $self->{OldStatus}, $NewStatus);
    }
  }
}

=pod
=over 12

=item C<UpdateStatus()>

Updates the status of this job and of its steps and tasks. Part of this means
checking for failed builds and skipping the subsequent tasks, or detecting
dead child processes.

Returns the updated status.

=back
=cut

sub UpdateStatus($)
{
  my ($self) = @_;

  my $Status = $self->Status;
  return $Status if ($Status ne "queued" && $Status ne "running");

  my (%Has, $Skip);
  my @SortedSteps = sort { $a->No <=> $b->No } @{$self->Steps->GetItems()};
  foreach my $Step (@SortedSteps)
  {
    my $StepStatus = $Step->UpdateStatus($Skip);
    $Has{$StepStatus} = 1;

    if ($StepStatus ne "queued" && $StepStatus ne "running" &&
        $StepStatus ne "completed" &&
        ($Step->Type eq "build" || $Step->Type eq "reconfig"))
    {
      # The following steps need binaries that this one was supposed to
      # produce. So skip them.
      $Skip = 1;
    }
  }

  # Inherit the steps most significant status.
  # Note that one or more tasks may have been requeued during the cleanup phase
  # of the server startup. So this job may regress from 'running' back to
  # 'queued'. This means all possible step status values must be considered.
  foreach my $StepStatus ("running", "boterror", "badpatch", "badbuild", "canceled", "skipped", "completed", "queued")
  {
    if ($Has{$StepStatus})
    {
      if ($Has{"queued"})
      {
        # Either nothing ran so this job is still / again 'queued', or not
        # everything has been run yet which means it's still 'running'.
        $Status = $StepStatus eq "queued" ? "queued" : "running";
      }
      else
      {
        # If all steps are skipped it's because the user canceled the job
        # before any of them could run.
        $Status = $StepStatus eq "skipped" ? "canceled" : $StepStatus;
      }
      $self->Status($Status);
      if ($Status ne "running" && $Status ne "queued" && !defined $self->Ended)
      {
        $self->Ended(time);
      }
      $self->Save();
      last;
    }
  }

  return $Status;
}

=pod
=over 12

=item C<Cancel()>

Cancels the Job, preserving existing results.

More precisely, goes through all of that Job's 'queued' and 'running' tasks,
killing all the running ones and marking them, and all the queued tasks, as
'skipped' so they will not be run. The overall Job status will be 'canceled'
unless it was completed already.

Returns undef if successful, the error message otherwise.

=back
=cut

sub Cancel($)
{
  my ($self) = @_;
  my $ErrMessage;

  my $Steps = $self->Steps;
  $Steps->AddFilter("Status", ["queued", "running"]);
  foreach my $Step (@{$Steps->GetItems()})
  {
    my $Tasks = $Step->Tasks;
    $Tasks->AddFilter("Status", ["queued", "running"]);
    foreach my $Task (@{$Tasks->GetItems()})
    {
      if ($Task->Status eq "queued")
      {
        $Task->Status("skipped");
        my ($EProperty, $EMessage) = $Task->Save();
        $ErrMessage ||= "$EMessage ($EProperty)" if ($EMessage);
      }
      elsif (defined $Task->ChildPid)
      {
        require WineTestBot::Log;
        WineTestBot::Log::LogMsg("Canceling the " . join("/", $self->Id, $Step->No, $Task->No) . " task\n");
        kill("TERM", $Task->ChildPid);
        $Task->Status("canceled");
        $Task->ChildPid(undef);
        my ($EProperty, $EMessage) = $Task->Save();
        $ErrMessage ||= "$EMessage ($EProperty)" if ($EMessage);

        my $VM = $Task->VM;
        $VM->Status('dirty');
        ($EProperty, $EMessage) = $VM->Save();
        $ErrMessage ||= "$EMessage ($EProperty)" if ($EMessage);
      }
    }
  }
  # Let UpdateStatus() handle updating the overall job status
  $self->UpdateStatus();

  return $ErrMessage;
}

=pod
=over 12

=item C<Restart()>

Restarts the Job from scratch.

More precisely, if the Job is not 'queued' or 'running', goes through all of
its tasks and marks them all as 'queued', deleting any existing result in the
process.

Returns undef if successful, the error message otherwise.

=back
=cut

sub Restart($)
{
  my ($self) = @_;

  if ($self->Status eq "queued" || $self->Status eq "running")
  {
    return "This job is already " . $self->Status;
  }

  my $JobDir = "$DataDir/jobs/" . $self->Id;
  my $FirstStep = 1;
  my $Steps = $self->Steps;
  my @SortedSteps = sort { $a->No <=> $b->No } @{$Steps->GetItems()};
  foreach my $Step (@SortedSteps)
  {
    my $Tasks = $Step->Tasks;
    foreach my $Task (@{$Tasks->GetItems()})
    {
      if ($FirstStep)
      {
        # The first step contains the patch or test executable
        # so only delete its task folders
        system("rm", "-rf", "$JobDir/" . $Step->No . "/" . $Task->No);
      }
      $Task->Status("queued");
      $Task->ChildPid(undef);
      $Task->Started(undef);
      $Task->Ended(undef);
      $Task->TestFailures(undef);
    }
    # Subsequent steps only contain files generated by the previous steps
    system("rm", "-rf", "$JobDir/" . $Step->No) if (!$FirstStep);
    $FirstStep = undef;
    $Step->Status("queued");
  }
  $self->Status("queued");
  $self->Submitted(time);
  $self->Ended(undef);
  my ($ErrProperty, $ErrMessage) = $self->Save(); # Save it all
  return "$ErrMessage ($ErrProperty)" if ($ErrMessage);

  return undef;
}

sub GetEMailRecipient($)
{
  my ($self) = @_;

  if (defined($self->Patch) && defined($self->Patch->FromEMail))
  {
    return $self->Patch->FromEMail;
  }

  if ($self->User->EMail eq "/dev/null")
  {
    return undef;
  }

  return $self->User->GetEMailRecipient();
}

sub GetDescription($)
{
  my ($self) = @_;

  if (defined($self->Patch) && defined($self->Patch->FromEMail))
  {
    return $self->Patch->Subject;
  }

  return $self->Remarks;
}


package WineTestBot::Jobs;

=head1 NAME

WineTestBot::Jobs - A Job collection

=head1 DESCRIPTION

This collection contains all known jobs: those have have been run as well as
those that are yet to be run.

=cut

use ObjectModel::BasicPropertyDescriptor;
use ObjectModel::EnumPropertyDescriptor;
use ObjectModel::DetailrefPropertyDescriptor;
use ObjectModel::ItemrefPropertyDescriptor;
use ObjectModel::PropertyDescriptor;
use WineTestBot::WineTestBotObjects;
use WineTestBot::Branches;
use WineTestBot::Config;
use WineTestBot::Patches;
use WineTestBot::Steps;
use WineTestBot::Users;
use WineTestBot::VMs;

use vars qw(@ISA @EXPORT @PropertyDescriptors);

require Exporter;
@ISA = qw(WineTestBot::WineTestBotCollection Exporter);
@EXPORT = qw(&CreateJobs &ScheduleJobs &CheckJobs);

my @PropertyDescriptors;

BEGIN
{
  @PropertyDescriptors = (
    CreateBasicPropertyDescriptor("Id", "Job id", 1, 1, "S",  5),
    CreateBasicPropertyDescriptor("Archived", "Job is archived", !1, 1, "B", 1),
    CreateItemrefPropertyDescriptor("Branch", "Branch", !1, 1, \&CreateBranches, ["BranchName"]),
    CreateItemrefPropertyDescriptor("User", "Author", !1, 1, \&WineTestBot::Users::CreateUsers, ["UserName"]),
    CreateBasicPropertyDescriptor("Priority", "Priority", !1, 1, "N", 1),
    CreateEnumPropertyDescriptor("Status", "Status", !1, 1, ['queued', 'running', 'completed', 'badpatch', 'badbuild', 'boterror', 'canceled']),
    CreateBasicPropertyDescriptor("Remarks", "Remarks", !1, !1, "A", 128),
    CreateBasicPropertyDescriptor("Submitted", "Submitted", !1, !1, "DT", 19),
    CreateBasicPropertyDescriptor("Ended", "Ended", !1, !1, "DT", 19),
    CreateItemrefPropertyDescriptor("Patch", "Submitted from patch", !1, !1, \&WineTestBot::Patches::CreatePatches, ["PatchId"]),
    CreateDetailrefPropertyDescriptor("Steps", "Steps", !1, !1, \&CreateSteps),
  );
}

sub CreateItem($)
{
  my ($self) = @_;

  return WineTestBot::Job->new($self);
}

sub CreateJobs(;$)
{
  my ($ScopeObject) = @_;
  return WineTestBot::Jobs->new("Jobs", "Jobs", "Job", \@PropertyDescriptors,
                                $ScopeObject);
}

sub CompareJobPriority
{
  return $a->Priority <=> $b->Priority || $a->Id <=> $b->Id;
}

sub CompareTaskStatus
{
  return $b->Status cmp $a->Status || $a->No <=> $b->No;
}

sub min(@)
{
  my $m = shift @_;
  map { $m = $_ if ($_ < $m) } (@_);
  return $m;
}

=pod
=over 12

=item C<ScheduleOnHost()>

This manages the VMs and WineTestBot::Task objects corresponding to the
hypervisors of a given host. To stay within the host's resource limits the
scheduler must take the following constraints into account:
=over

=item *

Jobs should be run in decreasing order of priority.

=item *

A Job's Steps must be run in sequential order.

=item *

A Step's tasks can be run in parallel but only one task can be running in a VM
at a given time. Also a VM must be prepared before it can run its task, see the
VM Statuses.

=item *

The number of active VMs on the host must be kept under $MaxActiveVMs. This
includes any VM using resources, including those that are being reverted. The
rational behind this limit is that the host may not be able to run more VMs
simultaneously, typically due to memory or CPU constraints. Also note that
this limit must be respected even if there is more than one hypervisor running
on the host.

=item *

The number of VMs being reverted on the host at a given time must be kept under
$MaxRevertingVMs, or $MaxRevertsWhileRunningVMs if some VMs are currently
running tests. This may be set to 1 in case the hypervisor gets confused when
reverting too many VMs at once.

=item *

Once there are no jobs to run anymore the scheduler can prepare up to
$MaxVMsWhenIdle VMs (or $MaxActiveVMs if not set) for future jobs. This can be
set to 0 to minimize the TestBot resource usage when idle.

=cut

=back
=cut

sub ScheduleOnHost($$$)
{
  my ($ScopeObject, $SortedJobs, $Hypervisors) = @_;


  my $HostVMs = CreateVMs($ScopeObject);
  $HostVMs->FilterEnabledRole();
  $HostVMs->FilterHypervisors($Hypervisors);

  # Count the VMs that are 'active', that is, that use resources on the host,
  # and those that are reverting. Also build a prioritized list of those that
  # are ready to run tests: the idle ones.
  my ($RevertingCount, $RunningCount, $IdleCount) = (0, 0, 0);
  my (%VMPriorities, %IdleVMs, @DirtyVMs);
  foreach my $VM (@{$HostVMs->GetItems()})
  {
    my $VMKey = $VM->GetKey();
    my $VMStatus = $VM->Status;
    if ($VMStatus eq "reverting")
    {
      $RevertingCount++;
    }
    elsif ($VMStatus eq "running")
    {
      $RunningCount++;
    }
    else
    {
      my $Priority = $VM->Type eq "build" ? 10 :
                     $VM->Role ne "base" ? 0 :
                     $VM->Type eq "win32" ? 1 : 2;
      $VMPriorities{$VMKey} = $Priority;

      # Consider sleeping VMs to be 'almost idle'. We will check their real
      # status before starting a job on them anyway. But if there is no such
      # job, then they are expandable just like idle VMs.
      if ($VMStatus eq "idle" || $VMStatus eq "sleeping")
      {
        $IdleCount++;
        $IdleVMs{$VMKey} = 1;
      }
      elsif ($VMStatus eq "dirty")
      {
        push @DirtyVMs, $VMKey;
      }
    }
  }

  # It usually takes longer to revert a VM than to run a test. So readyness
  # (idleness) trumps the Job priority and thus we start jobs on the idle VMs
  # right away. Then we build a prioritized list of VMs to revert.
  my (%VMsToRevert, @VMsNext);
  my ($RevertNiceness, $SleepingCount) = (0, 0);
  foreach my $Job (@$SortedJobs)
  {
    my $Steps = $Job->Steps;
    $Steps->AddFilter("Status", ["queued", "running"]);
    my @SortedSteps = sort { $a->No <=> $b->No } @{$Steps->GetItems()};
    if (@SortedSteps != 0)
    {
      my $Step = $SortedSteps[0];
      $Step->HandleStaging($Job->GetKey());
      my $PrepareNextStep;
      my $Tasks = $Step->Tasks;
      $Tasks->AddFilter("Status", ["queued"]);
      my @SortedTasks = sort CompareTaskStatus @{$Tasks->GetItems()};
      foreach my $Task (@SortedTasks)
      {
        my $VM = $Task->VM;
        my $VMKey = $VM->GetKey();
        next if (!$HostVMs->ItemExists($VMKey) || exists $VMsToRevert{$VMKey});

        my $VMStatus = $VM->Status;
        if ($VMStatus eq "idle" &&
            ($RevertingCount == 0 || $MaxRevertsWhileRunningVMs > 0))
        {
          $IdleVMs{$VMKey} = 0;
          $IdleCount--;

          my $ErrMessage = $Task->Run($Step);
          return $ErrMessage if (defined $ErrMessage);

          $Job->UpdateStatus();
          $RunningCount++;
          $PrepareNextStep = 1;
        }
        elsif ($VMStatus eq "sleeping" and $IdleVMs{$VMKey})
        {
          # It's not running jobs yet but soon will be
          # so it's not a candidate for shutdown.
          $IdleVMs{$VMKey} = 0;
          $IdleCount--;
          $SleepingCount++;
          $PrepareNextStep = 1;
        }
        elsif ($VMStatus eq "off" || $VMStatus eq "dirty")
        {
          $RevertNiceness++;
          $VMsToRevert{$VMKey} = $RevertNiceness;
        }
      }
      if ($PrepareNextStep && @SortedSteps >= 2)
      {
        # Build a list of VMs we will need next
        my $Step = $SortedSteps[1];
        $Tasks = $Step->Tasks;
        $Tasks->AddFilter("Status", ["queued"]);
        @SortedTasks = sort CompareTaskStatus @{$Tasks->GetItems()};
        foreach my $Task (@SortedTasks)
        {
          my $VM = $Task->VM;
          my $VMKey = $VM->GetKey();
          push @VMsNext, $VMKey;
          # Not a candidate for shutdown
          $IdleVMs{$VMKey} = 0;
        }
      }
    }
  }

  # Figure out how many VMs we will actually be able to revert now and only
  # keep the highest priority ones.
  my @SortedVMsToRevert = sort { $VMsToRevert{$a} <=> $VMsToRevert{$b} } keys %VMsToRevert;
  # Sleeping VMs will soon be running
  my $MaxReverts = ($RunningCount > 0) ?
                   $MaxRevertsWhileRunningVMs : $MaxRevertingVMs;
  my $ActiveCount = $IdleCount + $SleepingCount + $RunningCount + $RevertingCount;
  my $RevertableCount = min(scalar(@SortedVMsToRevert),
                            $MaxReverts - $RevertingCount,
                            $MaxActiveVMs - ($ActiveCount - $IdleCount));
  if ($RevertableCount < @SortedVMsToRevert)
  {
    $RevertableCount = 0 if ($RevertableCount < 0);
    for (my $i = $RevertableCount; $i < @SortedVMsToRevert; $i++)
    {
      my $VMKey = $SortedVMsToRevert[$i];
      delete $VMsToRevert{$VMKey};
    }
    splice @SortedVMsToRevert, $RevertableCount;
  }

  # Power off all the VMs that we won't be reverting now so they don't waste
  # resources while waiting for their turn.
  foreach my $VMKey (@DirtyVMs)
  {
    if (!exists $VMsToRevert{$VMKey})
    {
      my $VM = $HostVMs->GetItem($VMKey);
      # FIXME Domain operations can be slow and should not be run by the Engine
      my $ErrMessage = $VM->GetDomain()->PowerOff();
      return $ErrMessage if (defined $ErrMessage);
    }
  }

  # Power off some idle VMs we don't need immediately so we can revert more
  # of the VMs we need now.
  if ($IdleCount > 0 && @SortedVMsToRevert > 0 &&
      $ActiveCount + @SortedVMsToRevert > $MaxActiveVMs)
  {
    # Sort from least important to most important
    my @SortedIdleVMs = sort { $VMPriorities{$a} <=> $VMPriorities{$b} } keys %IdleVMs;
    foreach my $VMKey (@SortedIdleVMs)
    {
      my $VM = $HostVMs->GetItem($VMKey);
      next if (!$IdleVMs{$VMKey});

      # FIXME Domain operations can be slow and should not be run by the Engine
      my $ErrMessage = $VM->GetDomain()->PowerOff();
      return $ErrMessage if (defined $ErrMessage);
      $IdleCount--;
      $ActiveCount--;
      last if ($ActiveCount + @SortedVMsToRevert <= $MaxActiveVMs);
    }
  }

  # Revert the VMs that are blocking jobs
  foreach my $VMKey (@SortedVMsToRevert)
  {
    my $VM = $HostVMs->GetItem($VMKey);
    delete $VMPriorities{$VMKey};
    my $ErrMessage = $VM->RunRevert();
    return $ErrMessage if (defined $ErrMessage);
  }
  $RevertingCount += @SortedVMsToRevert;
  $ActiveCount += @SortedVMsToRevert;

  # Prepare some VMs for the current jobs next step
  foreach my $VMKey (@VMsNext)
  {
    last if ($RevertingCount == $MaxReverts);
    last if ($ActiveCount == $MaxActiveVMs);

    my $VM = $HostVMs->GetItem($VMKey);
    next if ($VM->Status ne "off");

    my $ErrMessage = $VM->RunRevert();
    return $ErrMessage if (defined $ErrMessage);
    $RevertingCount++;
    $ActiveCount++;
  }

  # Finally, if we are otherwise idle, prepare some VMs for future jobs
  my $MaxIdleVMs = defined $MaxVMsWhenIdle ? $MaxVMsWhenIdle : $MaxActiveVMs;
  if ($ActiveCount - $IdleCount == 0 && $ActiveCount < $MaxIdleVMs)
  {
    # Sort from most important to least important
    my @SortedVMs = sort { $VMPriorities{$b} <=> $VMPriorities{$a} } keys %VMPriorities;
    foreach my $VMKey (@SortedVMs)
    {
      last if ($RevertingCount == $MaxReverts);
      last if ($ActiveCount >= $MaxIdleVMs);

      my $VM = $HostVMs->GetItem($VMKey);
      next if ($VM->Status ne "off");

      my $ErrMessage = $VM->RunRevert();
      return $ErrMessage if (defined $ErrMessage);
      $RevertingCount++;
      $ActiveCount++;
    }
  }

  return undef;
}

=pod
=over 12

=item C<ScheduleJobs()>

Goes through the WineTestBot hosts and schedules the Job tasks on each of
them using WineTestBot::Jobs::ScheduleOnHost().

=back
=cut

sub ScheduleJobs()
{
  my $Jobs = CreateJobs();
  $Jobs->AddFilter("Status", ["queued", "running"]);
  my @SortedJobs = sort CompareJobPriority @{$Jobs->GetItems()};
  # Note that even if there are no jobs to schedule
  # we should check if there are VMs to revert

  my %Hosts;
  my $VMs = CreateVMs($Jobs);
  $VMs->FilterEnabledRole();
  foreach my $VM (@{$VMs->GetItems()})
  {
    my $Host = $VM->GetHost();
    $Hosts{$Host}->{$VM->VirtURI} = 1;
  }

  my @ErrMessages;
  foreach my $Host (keys %Hosts)
  {
    my @HostHypervisors = keys %{$Hosts{$Host}};
    my $HostErrMessage = ScheduleOnHost($Jobs, \@SortedJobs, \@HostHypervisors);
    push @ErrMessages, $HostErrMessage if (defined $HostErrMessage);
  }
  return @ErrMessages ? join("\n", @ErrMessages) : undef;
}

=pod
=over 12

=item C<CheckJobs()>

Goes through the list of Jobs and updates their status. As a side-effect this
detects failed builds, dead child processes, etc.

=back
=cut

sub CheckJobs()
{
  my $Jobs = CreateJobs();
  $Jobs->AddFilter("Status", ["queued", "running"]);
  map { $_->UpdateStatus(); } @{$Jobs->GetItems()};

  return undef;
}

sub FilterNotArchived($)
{
  my ($self) = @_;

  $self->AddFilter("Archived", [!1]);
}

1;
