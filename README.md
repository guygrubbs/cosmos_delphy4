# DELPHY Interface for COSMOS v4

This directory contains files and scripts that integrate a **DELPHY** system with COSMOS v4. The files provide the ability to:

1. **Connect** to the DELPHY hardware (over TCP/IP or another protocol).  
2. **Send** raw commands and script-based commands (like `run(...)`).  
3. **Receive** telemetry by decoding custom packets (`0xDEADBEEF` sync).  
4. **Wait** for acknowledgments (`ACK`) and completions (`COMPLETION`) with timeouts.  

Below is a summary of each file and how it fits into the COSMOS structure.

---

## Directory Structure

```
config/
  targets/
    delphy/
      target.txt
      cmd_tlm/
        delphy_tlm.txt
      lib/
        delphy_decoder.rb
        delphy_commands.rb
      procedures/
        delphy_periodic_commands.rb  (optional example script)
```

---

## File Descriptions

### 1. `target.txt`
- **Location**: `config/targets/delphy/target.txt`
- **Purpose**: Defines the COSMOS **target** for DELPHY, specifying:
  - Interface name (`DELPHY_INT`)  
  - Protocol (e.g., `TCPIP_CLIENT`)  
  - Host and port (`HOST`, `PORT`)  
  - Packet buffer size and **BINARY/RAW** data mode  
  - Custom user data router linking to `delphy_decoder.rb`
- **Key Lines**:
  ```plaintext
  TARGET DELPHY
  INTERFACE DELPHY_INT
    PROTOCOL TCPIP_CLIENT
    HOST 127.0.0.1
    PORT 5000
    BINARY
    USER_DATA_ROUTER ruby:config/targets/delphy/lib/delphy_decoder.rb:Delphy::Decoder
  ```

### 2. `delphy_tlm.txt`
- **Location**: `config/targets/delphy/cmd_tlm/delphy_tlm.txt`
- **Purpose**: Defines the **telemetry packets** recognized by COSMOS for DELPHY, such as:
  - `DELPHY_MESSAGE`  
  - `DELPHY_ACKNOWLEDGE`  
  - `DELPHY_COMPLETION`  
  - `DELPHY_STATUS`  
- **Contents**: Each packet has an ID (`0x1001`, etc.) and a list of items (e.g., `LEVEL`, `LEN`, `MESSAGE` for a message packet).  
- **Example**:
  ```plaintext
  TELEMETRY DELPHY DELPHY_MESSAGE 0x1001
    ITEM LEVEL 32 UINT
    ITEM LEN   32 UINT
    ITEM MESSAGE 256 STRING
  ```

### 3. `delphy_decoder.rb`
- **Location**: `config/targets/delphy/lib/delphy_decoder.rb`
- **Purpose**: A **custom Ruby stream decoder** to parse raw incoming bytes:
  1. Looks for the sync word `0xDEADBEEF`.  
  2. Extracts packet header fields (`type`, `id`, `sessionTime`, `packetTime`, `length`).  
  3. Routes the data to specific telemetry packets (`DELPHY_MESSAGE`, `DELPHY_ACKNOWLEDGE`, `DELPHY_COMPLETION`) based on `packet.type`.  
- **Key Steps**:
  - Accumulate incoming data in a buffer.  
  - Loop until all complete packets are extracted.  
  - Publish telemetry with `Cosmos::Packet`, populating each field.

### 4. `delphy_commands.rb`
- **Location**: `config/targets/delphy/lib/delphy_commands.rb`
- **Purpose**: A **library** of Ruby methods for:
  1. **Connecting** to DELPHY (`connect_to_delphy`), sending a **PKT_TYPE_IDENTITY** packet.  
  2. **Building** raw packets (`make_packet`), including the `0xDEADBEEF` sync word, packet ID, times, and payload.  
  3. **Sending** packets (`send_packet`) to the `DELPHY_INT` interface.  
  4. **Waiting** for ACK and COMPLETION telemetry (`wait_for_ack`, `wait_for_completion`) with configurable timeouts.  
  5. **High-Level Commands** for:
     - `send_inner_rotation(angle_degrees)`  
     - `send_outer_rotation(angle_degrees)`  
     - `send_horizontal_motion(distance_mm)`  
     - `send_vertical_motion(distance_mm)`  
     - (All of these wrap a `run(script_name(), parameter)` command string for PKT_TYPE_SCRIPT.)
- **Example Usage** (in another script):
  ```ruby
  require_relative '../lib/delphy_commands'
  Delphy.connect_to_delphy(14)           # Connect & send ID
  Delphy.send_inner_rotation(45)         # 45 degrees
  Delphy.send_horizontal_motion(20)      # 20 mm
  ```

### 5. `delphy_periodic_commands.rb` (Optional Example)
- **Location**: `config/targets/delphy/procedures/delphy_periodic_commands.rb`
- **Purpose**: Demonstrates a **script** that:
  1. Connects to DELPHY using `Delphy.connect_to_delphy(...)`.  
  2. Periodically sends a sequence of commands (e.g., rotating by 0°, 45°, 90°, etc.).  
  3. Waits for each command’s ACK/COMPLETION.  
- **Key Lines**:
  ```ruby
  def delphy_periodic_main
    Delphy.connect_to_delphy(14)
    Delphy.send_inner_rotation(45)
    wait(1.0)
    Delphy.send_outer_rotation(90)
    # etc.
  end
  ```
- You can run this **procedure** via COSMOS’s Procedure Launcher or from the command line.

---

## Getting Started

1. **Place Files**: Ensure all the files are in the correct paths:
   - `target.txt` in `config/targets/delphy/`  
   - `delphy_tlm.txt` in `config/targets/delphy/cmd_tlm/`  
   - `delphy_decoder.rb` in `config/targets/delphy/lib/`  
   - `delphy_commands.rb` in `config/targets/delphy/lib/`  
   - (Optional) `delphy_periodic_commands.rb` in `config/targets/delphy/procedures/`

2. **Configure** the **host/port** in `target.txt` to match your DELPHY device’s IP address or connection method.

3. **Launch COSMOS** and open:
   - **Command Sender** to send any other commands if you define them.  
   - **Telemetry Viewer** to watch the `DELPHY_MESSAGE`, `DELPHY_ACKNOWLEDGE`, `DELPHY_COMPLETION`, etc.  
   - **Procedure Launcher** to run example scripts like `delphy_periodic_commands.rb`.

4. **Check Logs**:
   - COSMOS logs events in `/logs/`.  
   - The `Cosmos::Logger.info(...)` calls in `delphy_commands.rb` provide details on sent packets, acknowledgments, etc.

5. **Common Edits**:
   - Change `machine_id` from `14` to your actual ID.  
   - Adjust timeouts in `wait_for_ack` and `wait_for_completion` if your system is slower/faster.  
   - Modify `run(...)` strings for your actual script commands if they differ from the examples.

---

## Notes and Tips

- **Endianness**: The packet header uses big-endian for integers and doubles. If your hardware expects little-endian, edit the `pack/unpack` calls accordingly (`V` instead of `N`, `E` or `e` instead of `G`, etc.).  
- **No Automated “Check Sum”**: If you need checksums or CRC, incorporate them into the `make_packet` logic and the `delphy_decoder.rb` decoding process.  
- **Combine With Other Targets**: Because these are standard COSMOS scripts, you can run them alongside other targets/interfaces in the same COSMOS instance.  

---

## Further Customization

- **Timeout Handling**: If you want to do more than just log errors on timeouts, add a `rescue Delphy::TimeoutError => e` in your scripts to take corrective actions.  
- **Extended Commands**: If your system has additional scripts (e.g., `angle_adjustment_script`, `calibration_script`), just add more methods in `delphy_commands.rb` that call `send_script_command(script_name, parameter)`.  
- **Periodic Monitoring**: If you want to constantly poll `DELPHY_STATUS` or `DELPHY_MESSAGE`, you can create a separate procedure or use `Cosmos.watch_packet(...)` in a custom Ruby script.

---

## Conclusion

This **DELPHY** directory structure and set of files provide a **complete** COSMOS v4 integration for:

- **Raw packet** building/sending (like your Python GSEOS script).  
- **Custom decoding** of inbound telemetry.  
- **High-level** command methods for rotation/motion scripts.  
- **Timeout** and **logging** logic for robust control.  

Feel free to adapt and expand these scripts to match your specific hardware protocol and operational procedures.  