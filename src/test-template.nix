{ isInteractive, isVulnerable, cfg, hasFile, caseDir, clientCfg, curlCfg, enableClient, enableAttacker, attackerCfg, customVmMap, customNodeNames }:
{ pkgs, lib, ... }:

let 
  testCfg = if cfg ? test then cfg.test else 
    throw "No test configuration provided in report.";
  testScriptPath = if testCfg ? test_script_path then testCfg.test_script_path else null;
  testScriptYaml = if testCfg ? test_script then testCfg.test_script else null;
  
  mkYAML2Test = import ./nice-yaml2test.nix { inherit lib; };
  
  userTestScript = 
    if testScriptPath != null then
      if testScriptYaml != null then
        throw "Only one of 'test_script_path' or 'test_script' can be specified."
      else if hasFile testScriptPath then
        let
          normalizedPath = lib.removePrefix "./" testScriptPath;
        in
          builtins.readFile (caseDir + "/${normalizedPath}")
      else throw "${caseDir}/${lib.removePrefix "./" testScriptPath} specified in report.yaml does not exist."
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
          ${
          let
            isServiceWait = 
              if isInteractive then false
              else if attackerCfg ? server && attackerCfg.server ? wait_in_test_script 
                then attackerCfg.server.wait_in_test_script 
              else true;
            service = if isServiceWait then attackerCfg.server.service_name or "maliciousServer" else null;
          in
            if isServiceWait then 
              ''
                attacker.wait_for_unit("${service}")
              ''
            else ""
          }
          #${portWaits}
        ''
    else
      "";
  
  defaultCustomVMBlock = lib.concatMapStringsSep "\n" (nodeName: ''
    ${nodeName}.wait_for_unit("multi-user.target")
  '') customNodeNames;

  defaultWaitBlock = lib.concatStringsSep "\n" [
    defaultAttackerWaitBlock
    (if enableClient then "client.wait_for_unit(\"multi-user.target\")" else "")
    defaultCustomVMBlock
  ];

  repeats = if testCfg ? repeats then testCfg.repeats else 1;

  repeatableTestBlock = lib.concatStringsSep "\n" ([
    "start_all()"
    defaultWaitBlock
  ] ++ (if !isInteractive then [ userTestScript ] else [])
    ++ (if isInteractive then [ "print(\"INTERACTIVE MODE SETUP COMPLETE. READY FOR INTERACTIVE TESTING.\")" ] else [])
  );

  shutdownBlock = ''
for machine in machines:
  machine.shutdown()
'';

  # Indent blocks so they sit correctly inside the Python for-loop
  repeatableTestBlockRetryIndented = "        " + lib.replaceStrings ["\n"] ["\n        "] repeatableTestBlock;
  shutdownBlockRetryIndented = "        " + lib.replaceStrings ["\n"] ["\n        "] shutdownBlock;

  testScript = if repeats > 1 && !isInteractive then
    ''
attempt = 1
while attempt <= ${toString repeats}:
    print(f"Starting test attempt {attempt}...")
    try:
${repeatableTestBlockRetryIndented}
        print(f"Test attempt {attempt} succeeded.")
        break
    except Exception as exc:
        print(f"Test attempt {attempt} failed: {exc}")
${shutdownBlockRetryIndented}
        attempt += 1
        assert attempt <= ${toString repeats}, "All test attempts failed after ${toString repeats} retries."
    '' 
  else repeatableTestBlock;
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

    sshBackdoor.enable = if isInteractive then true else false;

    testScript = testScript;
  }