USE winetestbot;

ALTER TABLE VMs
  DROP VmxHost,
  DROP VmxFilePath,
  ADD VirtURI VARCHAR(64) NOT NULL
      AFTER Status,
  ADD VirtDomain VARCHAR(32) NOT NULL
      AFTER VirtURI;
