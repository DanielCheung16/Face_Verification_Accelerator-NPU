# MobileFaceNet Frontend RTL Notes

## Architecture Overview
The frontend of the MobileFaceNet hardware accelerator is split into Modular components to ensure reusability, easy debugging, and high throughput. 

### Data Path (Phase 1)
- **`mfn_sliding_window.sv`**: Implements the line buffer and 3x3 shift register array. It takes a stream of incoming pixels and dynamically forms a 3x3 parallel window to maximize data reuse.
- **`mfn_mac_array.sv`**: A fully parallel 9-multiplier array with an adder tree and accumulator. It performs a 9-element dot product in a single clock cycle.
- **`mfn_activation.sv`**: Handles the PReLU multiplication and hardware Right-Shift (`>> 10`) post-quantization logic to return the `int32` MAC output back to `int16`.

### Control Path (Phase 2)
- **`mfn_addr_gen.sv`**: Decoupled address generator. Instead of using expensive multipliers to calculate `c * H * W + h * W + w`, it uses hardware accumulators to track the 1D SRAM read/write pointers.
- **`mfn_controller.sv`**: The Main FSM. Strictly uses the Two-Process Methodology (`always_comb` for next-state logic, `always_ff` for state updates).

## Two-Process Methodology Reminder
All sequential modules MUST follow this pattern:
1. `always_comb` block to calculate `_next` signals.
2. `always_ff @(posedge clk or negedge rst_n)` block to assign `_reg <= _next`.
NO arithmetic or logic operations should occur inside the `always_ff` block!
