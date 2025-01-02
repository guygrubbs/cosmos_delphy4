# delphy_connect.rb
#
# COSMOS v4 procedure to connect to the DELPHY_INT interface and send an
# identity packet (PKT_TYPE_IDENTITY). This replicates the Python script's
# "_connect()" logic.

require 'cosmos'
require 'cosmos/script'
require 'cosmos/interfaces/interface'
require 'cosmos/logging/logger'

# Require the commands file so we can call Delphy.make_packet and Delphy.send_packet
require_relative '../lib/delphy_commands'

# This is the main procedure function that COSMOS calls.
def connect_to_delphy
  # Attempt to connect the interface
  begin
    connect_interface('DELPHY_INT')
    Cosmos::Logger.info("delphy_connect.rb: Successfully connected to DELPHY_INT")
  rescue => e
    Cosmos::Logger.error("delphy_connect.rb: Failed to connect to DELPHY_INT. Error: #{e.message}")
    message_box("Failed to connect to DELPHY_INT.\nError: #{e.message}", 'Connection Error')
    return
  end

  # Send an Identity packet (PKT_TYPE_IDENTITY = 10 by default).
  # We assume machine_id = 14 (as in your Python script).
  machine_id = 14
  begin
    # Prepare the machine_id as a 4-byte big-endian integer
    machine_id_data = [machine_id].pack('N')
    pkt = Delphy.make_packet(Delphy::PKT_TYPE_IDENTITY, machine_id_data)
    Delphy.send_packet(pkt)

    Cosmos::Logger.info("delphy_connect.rb: Sent PKT_TYPE_IDENTITY packet (machine_id=#{machine_id}).")
  rescue => e
    Cosmos::Logger.error("delphy_connect.rb: Failed to send PKT_TYPE_IDENTITY. Error: #{e.message}")
    message_box("Failed to send ID packet.\nError: #{e.message}", 'Connection Error')
    return
  end

  # Optionally, you could log or set a local status variable that says "Connected = true".
  # In some setups, you might also want to wait a bit or poll telemetry for confirmation.
  # For now, we'll assume this is sufficient to declare success.

  message_box("DELPHY connection established.\nIdentity packet sent successfully.", "DELPHY Connect", false)
end
  