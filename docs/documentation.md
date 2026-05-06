# NICE cURL YAML vulnerability report

This section provides detailed documentation on the structure of the YAML report file used in the NICE cURL vulnerability reporter library. This YAML file serves as the main entry point for the library, describing key parameters of the vulnerability. It is also recipe for reproducing the vulnerability, allowing the reviewer and other security researchers to be able to easily reproduce and understand the vulnerability.

## YAML report file

### Top-level fields:

Header fields:
- `cve_id`: CVE identifier (if assigned)
- `title`: concise title of the vulnerability

Main blocks:
- `curl`: defines the vulnerable curl package.
- `vm`: contains VM configuration for the manual reproduction and automated testing of the vulnerability.
- `test_script`: defines the test script to validate the vulnerability.
- `meta`: metadata for the vulnerability report (optional)

## `curl` block

```yaml
curl:
  strategy: <nixpkgs|source>
  target: <tool|library>
  # If strategy is "nixpkgs":
  package:
    curl_version: X.Y.Z
    commit: <git-commit-hash>
    sha256: <sha256:hash>
  # If strategy is "source":
  package:
    url: <url-to-source-archive>
    hash: <hash>
    extra_configure_flags: [ <extra-configure-flag1>, ... ]
```

- `strategy` defines the two ways of obtainting the curl package: fetching a specific version from `nixpkgs` or building from `source`.
- `target` specifies which component of curl is vulnerable and will be tested in this report: either the `tool` (curl CLI) or the `library` (libcurl).
- For `nixpkgs` strategy, specify the `curl_version` and the corresponding nixpkgs `commit` and its `sha256` hash to ensure reproducibility. This can be done automatically using the `nice-report.py` helper script or manually by looking up the nixpkgs history and calculating the hash with `nix-prefetch-url <url> --unpack`.
- For `source` strategy, provide the `url` to the source archive, its `hash`, can also be calculated using the `nice-report.py` helper script or manually with `nix hash convert --hash-algo sha256 --to sri <hash-from-nix-prefetch-url>`.

- Both options also support build-time configuration flags (under development).

### `curl` build flags

Curl supports many build configurations that can be specified with different flags during the build process. These options can be enabled in the `report.yaml` using these fields:

```yaml
curl:
  ...
  # strategy: nixpkgs
  package:
  ...
  tls_backend: <openssl|wolfssl|gnutls|rustls> # optional, default is openssl
  with_brotli: <true|false> # optional, default is false
  with_ares: <true|false> # optional, default is false
  with_gsasl: <true|false> # optional, default is false
  with_http2: <true|false> # optional, default is true
  with_http3: <true|false> # optional, default is false
  with_websocket: <true|false> # optional, default is false
  with_idn: <true|false> # optional, default is false
  with_ldap: <true|false> # optional, default is false
  with_psl: <true|false> # optional, default is false
  with_rtmp: <true|false> # optional, default is false
  with_scp: <true|false> # optional, default is true
  with_zlib: <true|false> # optional, default is true
  with_zstd: <true|false> # optional, default is false

  # strategy: source
  package:
  ...
  tls_backend: <openssl|wolfssl|gnutls|rustls> # optional, default is openssl
  with_nghttp2: <true|false> # optional, default is true
  with_zlib: <true|false> # optional, default is true
  with_libpsl: <true|false> # optional, default is false
  with_brotli: <true|false> # optional, default is false
  with_zstd: <true|false> # optional, default is false
  with_libidn2: <true|false> # optional, default is false
  enable_shared: <true|false> # optional, default is true
  enable_debug: <true|false> # optional, default is false
  do_check: <true|false> # optional, default is false
  disable_protocols: [ <protocol1>, ... ] # optional, list of protocols to disable, e.g. [ "aws", "basic-auth" ]
  extra_configure_flags: [ <extra-configure-flag1>, ... ] # optional

  # strategy: custom
```


## `vm` block

### VM options

There are 2 main types of interactions supported in curl vulnerabilities:
- `attack_pattern`: 
  - `remote`: provide 2 VMs (client and attacker) to simulate a remote attack scenario.
  - `local`: provide a single VM to simulate a local attack scenario.
  - `other`: (no predefined VMs) for other custom scenarios.

### Client block

```yaml
vm:
  client:
    config_path: vm-configs/client.nix
    disk_image_path: /full-path/to/client.qcow2
    internet_access: false
    # Only for libcurl vulnerabilities with the "library" target
    application:
      file_path: ./exploit/client
      build_config:
        source_file: client.c
        build_flags: ""
```

- `config_path` is optional to allow extending the default VM configuration for the client machine using NixOS configurations. If not provided, a default configuration (`vm-configs/client.nix`) will be used if the file exists.

- `disk_image_path` is optional to allow using a custom `qcow2` disk image for the NixOS VM. If not provided, a default disk image will be generated by NixOS tests framework based on the provided VM configuration. The path should be an absolute path to the `qcow2` file, it is recommended to place the `qcow2` files in a `disks/` directory inside the report directory to keep things organized.

- `internet_access` is optional and is set to `false` by default to ensure that the VM does not have access to the internet during the test execution, which is important for security and reproducibility. If set to `true`, the VM will have internet access, but it is recommended to keep it disabled unless the test scenario specifically requires it since it can introduce uncontrolled variability factors and affect the reproducibility of the tests.

- `application` is enabled when the curl's target is `library` and allows to specify a custom application that uses the vulnerable libcurl component.
  - `file_path` points to the application source code in the `exploit/` directory. By default, it takes all the files in the `exploit/client/` directory.
  - `build_config` defines how to build the application, with a `source_file` as the gcc source file and `build_flags` for any additional flags needed during compilation.

This puts an executable `start-client` in the VM that will be used in the test script to trigger the vulnerability.

### Attacker block

```yaml
vm:
  attacker:
    config_path: vm-configs/attacker.nix
    disk_image_path: /full-path/to/attacker.qcow2
    internet_access: false
    networking:
      allowed_tcp_ports: [ 8080 ]
    server:
      file_path: ./exploit/server
      service_name: "maliciousServer"
      wait_in_test_script: true
      # If the server is written in C
      language: c
      build_config:
        build_inputs: gcc            
        build_commands: gcc -o server server.c
        build_output: server
      run_command: ./server
      # If the server is written in Python
      language: python
      python_version: "3.12"
      python_packages: [ pwntools ]
      run_command: python3 exploit-server.py
```

- Similar to the client block, `config_path` (*optional*) allows extending the default VM configuration for the attacker machine. If not provided, a default configuration (`vm-configs/attacker.nix`) will be used if the file exists.
- `disk_image_path` is optional to allow using a custom `qcow2` disk image for the NixOS VM. If not provided, a default disk image will be generated by NixOS tests framework based on the provided VM configuration. The path should be an absolute path to the `qcow2` file, it is recommended to place the `qcow2` files in a `disks/` directory inside the report directory to keep things organized.
- `internet_access` is optional and is set to `false` by default to ensure that the VM does not have access to the internet during the test execution, which is important for security and reproducibility. If set to `true`, the VM will have internet access, but it is recommended to keep it disabled unless the test scenario specifically requires it since it can introduce uncontrolled variability factors and affect the reproducibility of the tests.
- `networking` for the attacker machine only allows inbound forwarding, so it specifies the `allowed_tcp_ports` that the attacker server will be listening on to receive incoming connections from the client VM.
- `server` defines the server application that simulates the attacker's malicious server to exploit the curl client. It supports both C and Python applications with different build configurations.
  - `file_path` (*optional*): points to the server application source code in the `exploit/` directory. By default, it takes all the files in the `exploit/attacker/` directory.
  - `service_name` (*optional*): field that specifies the name of the systemd service to run the server. If not provided, the default service name `maliciousServer` will be used. This is useful for cases where the server needs to be running before the test script starts, as it allows waiting for the service to be active before executing the attack command in the test script.
  - `wait_in_test_script` is a boolean flag that indicates whether the test script should automatically wait for the server to be ready before continuing.
  - For C applications, specify the `build_config` with `build_inputs` for any dependencies needed during compilation, `build_commands` for the commands to build the server, and `build_output` for the name of the output executable.
  - For Python applications, specify the `python_version`, any required `python_packages` to start the server. The Python dependencies can be found on the Nix search website, although most of these Python packages have the same name as in Nixpkgs.
  - `run_command` specifies the command to run the server application.

Port fields accept either:
- a single integer (e.g. `8080`)
- a list of integers (e.g. `[8080, 8081]`)

### Custom VMs block

```yaml
vm:
  custom_vms:
    <name>:
      config_path: vm-configs/<name>.nix
      disk_image_path: /full-path/to/<name>.qcow2
      internet_access: false
      networking:
        allowed_tcp_ports: [ ... ]
```

Each node under `vm.custom_vms.<name>` defines a custom VM configuration with the hostname `<name>`. This is useful for more complex scenarios that require more than 2 VMs or different types of interactions between the VMs. 

The custom VM configuration allows both receiving and sending traffic, so it specifies `allowed_tcp_ports` to allow inbound traffic to the VM similarly to the attacker block, but it also allows outbound traffic to any port by default. 

## Test script block

```yaml
test_script_path: test-script.py
# or
test_script:
  - wait:
      machine: attacker
      type: port
      port: 8080
  - run:
      machine: client
      command: curl http://attacker:8080
      timeout: 60
  - assert:
      type: check-file-contains
      machine: client
      params:
        file_path: /var/log/server.log
        content: "Error occurred"
```

- `test_script_path` is an optional field that overrides the `test_script` block with a custom test script located at the specified path. You can only decide to use either `test_script_path` or `test_script`, but not both.
- The `test_script` block defines the steps to validate the vulnerability. Each step is an action that can be either `wait`, `run`, or `assert`:
  - `wait` allows waiting for a certain condition to be met before proceeding to the next step. Types of wait actions:
    ```yaml
    - wait: # wait for a port to be open
        machine: <machine-name>
        type: port
        port: <port-number>
        timeout: <timeout-in-seconds> # optional, default is 60 seconds
    - wait: # wait for a service to be active
        machine: <machine-name>
        type: service  # or 'unit'
        service_name: <service-name>
        timeout: <timeout-in-seconds> # optional, default is 60 seconds
    - wait: # wait for a file to exist in the provided path
        machine: <machine-name>
        type: file
        path: <file-path>
        timeout: <timeout-in-seconds> # optional, default is 60 seconds
    ```
  - `run` allows running a command on a specified machine with an optional timeout.
    ```yaml
    - run:
      machine: <machine-name>
      command: <command-to-run>
      expected_status: <success|failure|any> # optional, default is success. 
      expected_exit_codes: [ <list-of-expected-exit-codes> ] # optional, if expected_status is failure but expected_exit_codes is not provided, it defaults to allow any non-zero exit code.
      timeout: <timeout-in-seconds> # optional, default is 60 seconds
    ```
  - `assert` allows making assertions to validate the vulnerability. Multiple assertion types are supported:
    ```yaml
    # Check if a user has root privileges
    - assert:
        name: check-root-gid
        machine: <machine-name>
        params:
          user: <username>

    # Check if a specific file exists or not within a certain period of time
    - assert:
        name: check-file-exists
        machine: <machine-name>
        params:
          file_path: <path-to-file>
          is_present: <true|false>  # optional, default is true
          timeout: <timeout-in-seconds>  # optional, default is 60

    # Check if a specific file contains the expected content within a certain period of time
    - assert:
        name: check-file-contains
        machine: <machine-name>
        params:
          file_path: <path-to-file>
          content: <expected-content>
          timeout: <timeout-in-seconds>  # optional, default is 60

    # Check if a specific file size equals the expected size within a certain period of time
    - assert:
        name: check-file-size-equals
        machine: <machine-name>
        params:
          file_path: <path-to-file>
          expected_size: <size-in-bytes>
          timeout: <timeout-in-seconds>  # optional, default is 60
    # Check if a specific message appears in the systemd service logs within a certain period of time
    - assert:
        name: check-service-log-contains
        machine: <machine-name>
        params:
          unit: <service-unit-name>
          check_message: <expected-message>
          failed_message: <custom-failure-message>  # optional
          timeout: <timeout-in-seconds>  # optional, default is 60

    # Check if a core dump file is generated with the expected signal number
    - assert:
        name: check-core-dump-exists
        machine: <machine-name>
        params:
          expected_signal: <signal-number>
          unit_name: <service-unit-name>  # optional, default is "backdoor.service"
          repeats: <number-of-retries>  # optional, default is 10
          repeat_command: <command-to-trigger-crash>  # optional

    # Check if the memory usage of a command exceeds a certain threshold
    - assert:
        name: check-memory-usage-high
        machine: <machine-name>
        params:
          command: <command-to-run>
          maximum_memory_bytes: <max-memory-in-bytes>

    # Check if CPU time of a command exceeds a certain threshold
    - assert:
        name: check-cpu-usage-high
        machine: <machine-name>
        params:
          command: <command-to-run>
          maximum_cpu_time_secs: <max-cpu-time-in-seconds>

    # Check if the execution time of a command is within a certain range
    - assert:
        name: check-exact-execution-time
        machine: <machine-name>
        params:
          command: <command-to-run>
          expected_time: <time-in-seconds>
          repeats: <number-of-runs>  # optional, default is 5
          tolerance: <tolerance-in-seconds>  # optional, default is 0.5

    # Check if a command is successfully/unsuccessfully executed with expected exit codes
    - assert:
        name: check-command-result-status
        machine: <machine-name>
        params:
          command: <command-to-run>
          expected_status: <success|failure>  # expected outcome of the command execution, must be defined
          expected_exit_codes: [ <list-of-expected-exit-codes> ]  # optional, if expected_status is failure but not provided, it defaults to allow any non-zero exit code.
          rationale: <rationale-for-assertion>  # a brief explanation of why this assertion is relevant for validating the vulnerability
          timeout: <timeout-in-seconds>  # optional, default is 60 seconds
    ```

