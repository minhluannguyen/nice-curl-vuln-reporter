{
  description = "Shared curl CVE Nix library";

  outputs = { self }:
    {
      lib.mkCurlCveCase = args: import ./curl-cve-lib.nix args;
    };
}
