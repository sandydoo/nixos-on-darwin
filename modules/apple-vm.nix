{ config, lib, pkgs, ... }:

{
  systemd.mounts = [
    {
      what = "ROSETTA";
      where = "/mnt/rosetta";
      type = "virtiofs";
      wantedBy = [ "multi-user.target" ];
      enable = true;
    }
  ];
}
