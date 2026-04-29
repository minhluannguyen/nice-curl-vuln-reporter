{ lib }:

let
  mkEscapedCommand = command: 
    let
      # First, handle shell line continuations (backslash-newline) by removing them
      withoutContinuations = lib.replaceStrings ["\\\n"] [""] command;
    in
    lib.pipe withoutContinuations [
      (s: lib.replaceStrings ["\\"] ["\\\\"] s)
      (s: lib.replaceStrings ["\""] ["\\\""] s)
      (s: lib.replaceStrings ["$"] ["\\$"] s)
      (s: lib.replaceStrings ["\'"] ["\\\'"] s)
      (s: lib.replaceStrings ["\n"] ["\\n"] s)
    ];

  # Translate a single action
  translateAction = action:
    let
      actionType = 
        if action ? "run" then "run"
        else if action ? "wait" then "wait"
        else if action ? "assert" then "assert"
        else throw "Unknown action type in: ${lib.generators.toPretty {} action}";
      
      actionData = if actionType == "assert" then action."assert" else action.${actionType};
    in
      if actionType == "run" then
        translateRun actionData
      else if actionType == "wait" then
        translateWait actionData
      else if actionType == "assert" then
        translateAssert actionData
      else
        throw "Unknown action type: ${actionType}";

  # Translate 'run' action - executes a command on a machine
  # run:
  #   machine: client
  #   command: curl http://attacker:8080
  #   timeout: 60
  translateRun = config:
    let
      machine = config.machine or (throw "run action requires 'machine' field");
      expectedStatus = if config ? expected_status then 
        if config.expected_status != "success" && config.expected_status != "failure" && config.expected_status != "any" then
          throw "Invalid value for expected_status: ${config.expected_status}. Allowed values are 'success', 'failure', or 'any'."
        else config.expected_status
      else "success"; # default to expecting success if not specified
      expectedExitCodes = if expectedStatus == "failure" then 
        if config ? expected_exit_codes then config.expected_exit_codes
        else null # if expecting failure but no exit codes specified, we won't check exit codes
      else null; # if not expecting failure, ignore any specified exit codes
      command = config.command or (throw "run action requires 'command' field");
      timeout = config.timeout or 60;
      escapedCommand = mkEscapedCommand command;
      # Format expected exit codes as Python list
      formattedExitCodes = if expectedExitCodes != null then "[${lib.concatStringsSep ", " (map toString expectedExitCodes)}]" else "1";
    in
      ''
        print("STEP: Running command on ${machine}: ${escapedCommand}")
        ${if expectedStatus == "success" then
          ''
            print('Note: This command is expected to succeed.')
            print(${machine}.succeed("${escapedCommand}", timeout=${toString timeout}))
          ''
        else if expectedStatus == "failure" && expectedExitCodes == null then
          ''
          print('Note: This command is expected to fail with exit codes: ${formattedExitCodes}')
          print(${machine}.fail("${escapedCommand}", timeout=${toString timeout}))
          ''
        else  
          ''
            print('Note: This command will be executed without restrictions on exit code or success/failure status')
            stdout = ${machine}.execute("${escapedCommand}", timeout=${toString timeout})
            print(stdout[1])
          ''
        }
        ${if expectedStatus == "failure" && expectedExitCodes != null then
          ''
            if stdout[0] not in ${formattedExitCodes}:
              raise Exception(f"Command on ${machine} failed with unexpected exit code: {stdout[0]}. Output: {stdout[1]}")
            print("EXIT CODE: " + str(stdout[0]))
          ''
          else ""
        }   
      '';

  # Translate 'wait' action - waits for conditions (port, service, file, etc)
  # wait:
  #   machine: attacker
  #   type: port
  #   port: 8080
  # OR
  # wait:
  #   machine: attacker
  #   type: service/unit
  #   service: server
  # OR
  # wait:
  #   machine: client
  #   type: file
  #   path: /tmp/result.txt
  translateWait = config:
    let
      machine = config.machine or (throw "wait action requires 'machine' field");
      waitType = config.type or (throw "wait action requires 'type' field");
      timeout = config.timeout or 60;
    in
      if waitType == "port" then
        let
          port = config.port or (throw "wait action with type 'port' requires 'port' field");
        in
          ''
            print("STEP: Waiting for port ${toString port} on ${machine}")
            ${machine}.wait_for_open_port(${toString port}, timeout=${toString timeout})
          ''
      else if waitType == "service" || waitType == "unit" then
        let
          service = config.service_name or config.unit_name or (throw "wait action with type 'service_name' requires 'service' or 'unit_name' field");
        in
          ''
            print("STEP: Waiting for service ${service} on ${machine}")
            ${machine}.wait_for_unit("${service}", timeout=${toString timeout})
          ''
      else if waitType == "file" then
        let
          path = config.path or (throw "wait action with type 'file' requires 'path' field");
        in
          ''
            print("STEP: Waiting for file ${path} on ${machine}")
            ${machine}.wait_for_file("${path}", timeout=${toString timeout})
          ''
      else
        throw "Unknown wait type: ${waitType}";

  # Translate 'assert' action - validates conditions using assertion blocks
  # assert:
  #   name: check-memory-usage-high
  #   machine: client
  #   params:
    #   command: curl http://attacker:8080
    #   maximum_memory_bytes: 536870912
  mkAssertion = import ./assertion/make-assertion.nix;
  
  # Extract assertion type from an action
  getAssertionType = action:
    if action ? "assert" then
      action."assert".name or (throw "assert action requires 'name' field")
    else
      null;
  
  # Get all unique assertion types from the test script
  getAllAssertionTypes = testScriptYaml:
    let
      types = map getAssertionType testScriptYaml;
      nonNullTypes = lib.filter (t: t != null) types;
    in
      lib.unique nonNullTypes;
  
  # Get assertion block definitions for a given type
  getAssertionDefinition = assertType:
    let
      assertionBlocks = import ./assertion/assertion-blocks.nix;
    in
      if assertType == "check-core-dump-exists" then
        assertionBlocks.check-core-dump-exists.definition
      else if assertType == "check-memory-usage-high" then
        assertionBlocks.check-memory-usage-high.definition
      else if assertType == "check-cpu-usage-high" then
        assertionBlocks.check-cpu-usage-high.definition
      else if assertType == "check-file-exists" then
        assertionBlocks.check-file-exists.definition
      else if assertType == "check-file-contains" then
        assertionBlocks.check-file-contains.definition
      else if assertType == "check-file-size-equals" then
        assertionBlocks.check-file-size-equals.definition
      else if assertType == "check-service-log-contains" then
        assertionBlocks.check-service-log-contains.definition
      else if assertType == "check-command-result-status" then
        assertionBlocks.check-command-result-status.definition
      else if assertType == "check-exact-execution-time" then
        assertionBlocks.check-exact-execution-time.definition
      else
        throw "Unknown assertion type: ${assertType}";
  
  translateAssert = config:
    let
      assertionBlock = mkAssertion config;
      assertType = config.name or (throw "assert action requires 'name' field");
      machine = config.machine or (throw "assert action requires 'machine' field");

      escapedRationale = if config.params ? rationale then mkEscapedCommand config.params.rationale else null;
    in
      ''
        print("ASSERTION: ${assertType} on ${machine}")
        ${if assertType == "check-command-result-status" then
            if !config.params ? rationale then 
              throw "Assert action with type 'check-command-result-status' requires 'rationale' field in params to explain the rationale for this assertion."
            else "print(\"Rationale: ${escapedRationale}\")"
          else ""
        }
        ${assertionBlock}
      '';
in
{
  testYAML2Script = testScriptYaml:
  let 
    translateTests = if testScriptYaml != null then
      map translateAction testScriptYaml
    else [];
    
    # Get all unique assertion types used in the test script
    assertionTypes = getAllAssertionTypes (if testScriptYaml != null then testScriptYaml else []);
    
    # Generate definitions for all assertion types
    assertionDefinitions = lib.concatStringsSep "\n" (map getAssertionDefinition assertionTypes);
  in
    if assertionTypes != [] then
      assertionDefinitions + "\n\n" + lib.concatStringsSep "\n" translateTests
    else
      lib.concatStringsSep "\n" translateTests;
}
