{ lib }:

let
  mkEscapedCommand = command: 
    lib.pipe command [
      (s: lib.replaceStrings ["\\"] ["\\\\"] s)
      (s: lib.replaceStrings ["\""] ["\\\""] s)
      (s: lib.replaceStrings ["$"] ["\\$"] s)
      (s: lib.replaceStrings ["\'"] ["\\\'"] s)
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
      isAllowedFail = config.allowed_fail or false;
      expectedExitCodes = if isAllowedFail then config.expected_exit_codes or null else null;
      command = config.command or (throw "run action requires 'command' field");
      timeout = config.timeout or 60;
      # Escape special characters for Python string: quotes, backslashes, dollar signs
      # First escape backslashes, then quotes, then dollar signs
      escapedCommand = mkEscapedCommand command;
      # Format expected exit codes as Python list
      formattedExitCodes = if expectedExitCodes != null then "[${lib.concatStringsSep ", " (map toString expectedExitCodes)}]" else null;
    in
      ''
        print("STEP: Running command on ${machine}: ${escapedCommand}")
        ${if isAllowedFail then "print('Note: This command is allowed to fail with exit codes: ${formattedExitCodes}')" else ""}
        ${if !isAllowedFail then 
          "print(${machine}.succeed(\"${escapedCommand}\", timeout=${toString timeout}))" 
        else 
          if expectedExitCodes == null then
            "print(${machine}.fail(\"${escapedCommand}\", timeout=${toString timeout}))"
          else  
          ''
            stdout = ${machine}.execute("${escapedCommand}", timeout=${toString timeout})
            if stdout[0] not in ${formattedExitCodes}:
              raise Exception(f"Command on ${machine} failed with unexpected exit code: {stdout[0]}. Output: {stdout[1]}")
            print(stdout[1])
            print("EXIT CODE: " + str(stdout[0]))
          ''
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
  # wait:
  #   machine: client
  #   type: command
  #   command: test -f /tmp/ready
  #   timeout: 90
  translateWait = config:
    let
      machine = config.machine or (throw "wait action requires 'machine' field");
      waitType = config.type or (throw "wait action requires 'type' field");
      timeout = config.timeout or 90;
    in
      if waitType == "port" then
        let
          port = config.port or (throw "wait action with type 'port' requires 'port' field");
        in
          ''
            print("STEP: Waiting for port ${toString port} on ${machine}")
            ${machine}.wait_for_open_port(${toString port})
          ''
      else if waitType == "service" || waitType == "unit" then
        let
          service = config.service_name or config.unit_name or (throw "wait action with type 'service_name' requires 'service' or 'unit_name' field");
        in
          ''
            print("STEP: Waiting for service ${service} on ${machine}")
            ${machine}.wait_for_unit("${service}")
          ''
      else if waitType == "file" then
        let
          path = config.path or (throw "wait action with type 'file' requires 'path' field");
        in
          ''
            print("STEP: Waiting for file ${path} on ${machine}")
            ${machine}.wait_for_file("${path}", timeout=${toString timeout})
          ''
      else if waitType == "command-success" then
        let
          command = config.command or (throw "wait action with type 'command' requires 'command' field");
          escapedCommand = mkEscapedCommand command;
        in
          ''
            print("STEP: Waiting for command to succeed on ${machine}")
            ${machine}.wait_until_succeeds("${escapedCommand}", timeout=${toString timeout})
          ''
      else if waitType == "command-fail" then
        let
          command = config.command or (throw "wait action with type 'command' requires 'command' field");
          escapedCommand = mkEscapedCommand command;
        in
          ''
            print("STEP: Waiting for command to fail on ${machine}")
            ${machine}.wait_until_fails("${escapedCommand}", timeout=${toString timeout})
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
  translateAssert = config:
    let
      assertionBlock = mkAssertion config;
      assertType = config.name or (throw "assert action requires 'name' field");
      machine = config.machine or (throw "assert action requires 'machine' field");

      escapedRationale = if config.params ? rational then mkEscapedCommand config.params.rational else null;
    in
      ''
        print("ASSERTION: ${assertType} on ${machine}")
        ${if assertType == "check-command-result-status" then
            if !config.params ? rational then 
              throw "Assert action with type 'check-command-result-status' requires 'rational' field in params to explain the rationale for this assertion."
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
  in
    lib.concatStringsSep "\n" translateTests;
}
