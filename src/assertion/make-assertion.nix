assertionCfg:
  let
    assertionBlocks = import ./assertion-blocks.nix;
    ap = assertionCfg.params or {};
    assertionType = assertionCfg.name or (throw "assert action requires 'type' field");
    assertionMachine = assertionCfg.machine or (throw "assert action requires 'machine' field");
    # Helper to escape special characters in strings for Python: backslashes, quotes, dollar signs
    # Process in order: backslashes first, then quotes, then dollar signs
    escapeQuotes = s: 
      let
        str = builtins.toString s;
        # First, handle shell line continuations (backslash-newline) by removing them
        withoutContinuations = builtins.replaceStrings ["\\\n"] [""] str;
        escaped1 = builtins.replaceStrings ["\\"] ["\\\\"] withoutContinuations;
        escaped2 = builtins.replaceStrings ["\""] ["\\\""] escaped1;
        escaped3 = builtins.replaceStrings ["$"] ["\\$"] escaped2;
      in
        escaped3;
  in
    if assertionType == "check-core-dump-exists" then
      assertionBlocks.check-core-dump-exists.call {
        machine = assertionMachine;
        expected_signal = ap.expected_signal;
        unit_name = ap.unit_name or "backdoor.service";
        repeats = ap.repeats or 10;
        repeat_command = escapeQuotes (ap.repeat_command or "");
      }
    else if assertionType == "check-memory-usage-high" then
      assertionBlocks.check-memory-usage-high.call {
        machine = assertionMachine;
        command = escapeQuotes ap.command;
        maximum_memory_usage = ap.maximum_memory_bytes;
      }
    else if assertionType == "check-cpu-usage-high" then
      assertionBlocks.check-cpu-usage-high.call {
        machine = assertionMachine;
        command = escapeQuotes ap.command;
        maximum_cpu_time_usage = ap.maximum_cpu_time_secs;
      }
    else if assertionType == "check-file-exists" then
      assertionBlocks.check-file-exists.call {
        machine = assertionMachine;
        file_path = escapeQuotes ap.file_path;
        is_present = ap.is_present or true;
        timeout = ap.timeout or 60;
      }
    else if assertionType == "check-file-contains" then
      assertionBlocks.check-file-contains.call {
        machine = assertionMachine;
        file_path = escapeQuotes ap.file_path;
        content = escapeQuotes ap.content;
        timeout = ap.timeout or 60;
      }
    else if assertionType == "check-service-log-contains" then
      assertionBlocks.check-service-log-contains.call {
        machine = assertionMachine;
        check_message = escapeQuotes ap.check_message;
        unit = escapeQuotes ap.unit;
        failed_message = escapeQuotes (ap.failed_message or "");
        timeout = ap.timeout or 60;
      }
    else if assertionType == "check-command-result-status" then
      assertionBlocks.check-command-result-status.call {
        machine = assertionMachine;
        command = escapeQuotes ap.command;
        expected_status = 
          if ap ? expected_status then
            if ap.expected_status != "success" && ap.expected_status != "failure" then throw "expected_status must be either 'success' or 'failure'" else ap.expected_status
          else throw "check-command-result-status assertion requires 'expected_status' field";
        expected_exit_codes = if ap.expected_status == "failure" then ap.expected_exit_codes or null else null;
        timeout = ap.timeout or 60;
      }
    else
      throw "Unknown assertion type: ${assertionType}"
