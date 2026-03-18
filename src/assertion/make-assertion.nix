assertionCfg:
  let
    assertionBlocks = import ./assertion-blocks.nix;
    ap = assertionCfg.params or {};
    assertionType = assertionCfg.name or "";
  in
    if assertionType == "core_dump" then
      assertionBlocks.check-core-dump-exists {
        machine = ap.machine;
        expected_signal = ap.expected_signal;
      }
    else if assertionType == "oom" then
      assertionBlocks.check-memory-usage-high {
        machine = ap.machine;
        command = ap.command;
        maximum_memory_usage = ap.maximum_memory_bytes;
      }
    else if assertionType == "cpu_spin" then
      assertionBlocks.check-cpu-usage-high {
        machine = ap.machine;
        command = ap.command;
        maximum_cpu_time_usage = ap.maximum_cpu_time_secs;
      }
    else if assertionType == "file_absent" then
      assertionBlocks.check-file-exists {
        machine = ap.machine;
        file_path = ap.file_path;
        is_existing = false;
      }
    else if assertionType == "file_present" then
      assertionBlocks.check-file-exists {
        machine = ap.machine;
        file_path = ap.file_path;
        is_existing = true;
      }
    else if assertionType == "file_content" then
      assertionBlocks.check-file-contains {
        machine = ap.machine;
        file_path = ap.file_path;
        content = ap.content;
      }
    else
      throw "Unknown assertion type: ${assertionType}"
