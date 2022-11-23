{ ... }:

{
  fileSystems."/media/rosetta" =  {
    device = "rosetta";
    fsType = "virtiofs";
  };

  boot.binfmt.registrations.rosetta = {
    interpreter = "/media/rosetta/rosetta";
    magicOrExtension = ''\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x3e\x00'';
    mask = ''\xff\xff\xff\xff\xff\xfe\xfe\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff'';
    preserveArgvZero = false;
    matchCredentials = true;
    fixBinary = true;
    wrapInterpreterInShell = false;
  };
}
