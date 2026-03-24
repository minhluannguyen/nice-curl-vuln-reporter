assertionCfg:
  let
    assertionBlocks = import ./assertion-blocks.nix;
    ap = assertionCfg.params or {};
    assertionType = assertionCfg.name or "";
  in
    if assertionType == "check-core-dump-exists" then
      assertionBlocks.check-core-dump-exists {
        machine = ap.machine;
        expected_signal = ap.expected_signal;
      }
    else if assertionType == "check-memory-usage-high" then
      assertionBlocks.check-memory-usage-high {
        machine = ap.machine;
        command = ap.command;
        maximum_memory_usage = ap.maximum_memory_bytes;
      }
    else if assertionType == "check-cpu-usage-high" then
      assertionBlocks.check-cpu-usage-high {
        machine = ap.machine;
        command = ap.command;
        maximum_cpu_time_usage = ap.maximum_cpu_time_secs;
      }
    else if assertionType == "check-file-exists" then
      assertionBlocks.check-file-exists {
        machine = ap.machine;
        file_path = ap.file_path;
        is_existing = ap.is_existing or true;
      }
    else if assertionType == "check-file-contains" then
      assertionBlocks.check-file-contains {
        machine = ap.machine;
        file_path = ap.file_path;
        content = ap.content;
      }
    else if assertionType == "check-service-log-contains" then
      assertionBlocks.check-service-log-contains {
        machine = ap.machine;
        check_message = ap.check_message;
        unit = ap.unit;
        failed_message = ap.failed_message or "";
      }
    else
      throw "Unknown assertion type: ${assertionType}"
