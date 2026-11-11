# ADRV9361-Z7035 port branch (`adrv9361z7035-2025.1`)

This branch carries the openwifi FPGA design changes for the ADRV9361-Z7035
SOM on the ADRV1CRR-BOB carrier, built with Vivado 2025.1.

- Upstream: [open-sdr/openwifi-hw](https://github.com/open-sdr/openwifi-hw)
- Base commit: `d047d79` (upstream `master`, "Put all board links in the README")
- Integration repository (single-entry hardware build in Tcl, release notes):
  [openwifi-adrv9361z7035](https://github.com/debitagrzegorz-netizen/openwifi-adrv9361z7035)
- Release tags: `adrv9361z7035-2025.1-v1.1` (`edbab1c`) and
  `adrv9361z7035-2025.1-v1.2` (`49e8ceb`)

Port commits on top of the base:

- `6c005e9` Record the Vivado 2025.1 ADRV9361 board design.
- `edbab1c` Cross the TX IQ sample into the DAC domain through an async FIFO.
- `49e8ceb` Restart the backoff when a retransmission is quit for queue 0.

The design uses the AMD/Xilinx Viterbi Decoder LogiCORE IP, which needs its
own Vivado licence (evaluation or full). The prebuilt bitstreams in this
history are upstream's, for other boards.

Licence: as upstream (AGPL-3.0, with the upstream dual-licence note).
