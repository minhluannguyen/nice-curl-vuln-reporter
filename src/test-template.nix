{ isVulnerable, cfg, hasFile, caseDir, clientCfg, curlCfg, enableAttacker, attackerCfg, customVmMap, customNodeNames }:
{ pkgs, lib, ... }:

let 
  testScriptPath = if cfg ? test_script_path then cfg.test_script_path else null;
  testScriptYaml = if cfg ? test_script then cfg.test_script else null;
  
  mkYAML2Test = import ./nice-yaml2test.nix { inherit lib; };
  
  testScript = if testScriptPath != null && hasFile testScriptPath then
    builtins.readFile (caseDir + "/" + testScriptPath)
  else if testScriptYaml != null then
    mkYAML2Test.testYAML2Script testScriptYaml
  else
    throw "No test script provided. Please specify either 'test_script_path' or 'test_script' in report.yaml.";

  defaultAttackerWaitBlock = 
    if enableAttacker then
      let
        inboundPorts = attackerCfg.networking.inbound_guest_ports or [];
        portWaits = lib.concatMapStringsSep "\n      " (port: ''attacker.wait_for_open_port(${toString port})'') inboundPorts;
      in
        ''
          attacker.wait_for_unit("multi-user.target")
          attacker.wait_for_unit("maliciousServer.service")
          ${portWaits}
        ''
    else
      "";

  defaultWaitBlock = lib.concatStringsSep "\n" [
    defaultAttackerWaitBlock
    "client.wait_for_unit(\"multi-user.target\")"
  ];
in
  pkgs.testers.runNixOSTest {
    name = "${cfg.cve_id}-${cfg.title}-${if isVulnerable then "vulnerable" else "non-vulnerable"}-test";
    nodes = 
    {
      client = (import ./vm-configs/vm-template-client.nix { inherit isVulnerable; isTest = true; inherit caseDir clientCfg curlCfg; });
    }
    // 
    lib.optionalAttrs enableAttacker {
      attacker = (import ./vm-configs/vm-template-attacker.nix { isTest = true; inherit caseDir attackerCfg; });
    }
    // 
    (builtins.listToAttrs (map
      (nodeName: {
        name = "${nodeName}";
        value = (import ./vm-configs/vm-template-custom.nix { isTest = true; hostname = nodeName; customMachineCfg = customVmMap.${nodeName}; inherit caseDir;});
      }) customNodeNames)
    );

    testScript = lib.concatStringsSep "\n" [
      "start_all()"
      defaultWaitBlock
      testScript
    ];
  }