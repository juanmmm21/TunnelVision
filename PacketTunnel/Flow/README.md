# PacketTunnel/Flow

`FlowTable` (bounded, LRU-evicted) and `TCPReassembler` (ordered stream, out-of-order/retransmit
handling, hard buffer caps → downgrade). Memory-bounded by design.

**Spec:** [`../../docs/spec/flow-and-reassembly.md`](../../docs/spec/flow-and-reassembly.md) · **Milestone:** M4
