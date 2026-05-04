//------------------------------------------------------------------
//PS!: The output signal needs to be delayed to match the reading 
//delay costed by Buffer
//Function:
// start_i is asserted
// → Enter RUN phase
// → feed_cycle starts incrementing from 0
// → skew_feeder generates the first signal
// → PEs overwrite old psums based on the first signal
// → Continue to DRAIN phase after feeding is complete
// → done_o is pulled high

// Output Interfaces:
// systolic_array: array_en_o
// skew_addr_gen: feed_valid_o, feed_cycle_o
// top/testbench/software: busy_o, done_o
//------------------------------------------------------------------
module array_controller #(
    parameter int ROW      = 14,
    parameter int COL      = 16,
    parameter int K_MAX    = 512,
    parameter int COUNT_W  = 16,
    parameter int K_ADDR_W = (K_MAX <= 1) ? 1 : $clog2(K_MAX)
) (
    input  logic               clk,
    input  logic               rst_n,
    //when psum saved and new data loaded, then assert start_i
    input  logic               start_i, 
    input  logic               run_en_i,
    // Runtime Channel dimension.
    // Valid range: 1 ... K_MAX.
    input  logic [K_ADDR_W:0]  k_size_i,
    // Current feeding cycle from controller.
    output logic [COUNT_W-1:0] feed_cycle_o,
    output logic               feed_valid_o,

    output logic               array_en_o,
    output logic               busy_o,
    output logic               done_o
);
    localparam MAX_ROW_COL = (ROW >= COL) ? ROW : COL;

    // logic   feed_valid_w;
    // logic   array_en_w;
    // logic   busy_w;
    // logic   done_w;

    typedef enum logic [1:0] {IDLE, RUN, DRAIN, DONE } state_t;
    state_t ctrl_state, ctrl_state_nxt;

    logic   [COUNT_W-1:0]  cycle_cnt, cycle_cnt_nxt;


    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ctrl_state  <= IDLE;
            cycle_cnt   <= '0;
            // feed_valid_o <= 1'b0;
            // array_en_o  <= 1'b0;
            // busy_o      <= 1'b0;
            // done_o      <= 1'b0;
        end else begin
            ctrl_state  <= ctrl_state_nxt;
            cycle_cnt   <= cycle_cnt_nxt;
            // feed_valid_o <= feed_valid_w;
            // array_en_o  <= array_en_w;
            // busy_o      <= busy_w;
            // done_o      <= done_w;
        end
    end

    always_comb begin
        ctrl_state_nxt  = ctrl_state;
        cycle_cnt_nxt   = cycle_cnt;
        //output data
        feed_valid_o    = 1'b0;
        array_en_o      = 1'b0;
        busy_o          = 1'b0;
        done_o          = 1'b0;

        case (ctrl_state)
            IDLE: begin
                cycle_cnt_nxt = '0;
                if(start_i && run_en_i) begin
                    ctrl_state_nxt = RUN;
                end
            end
            RUN: begin
                feed_valid_o = run_en_i;
                array_en_o   = run_en_i;
                busy_o       = 1'b1;
                if (run_en_i) begin
                    cycle_cnt_nxt = cycle_cnt + 1'b1;
                    if(cycle_cnt == (k_size_i + MAX_ROW_COL - 2))begin
                        ctrl_state_nxt = DRAIN;
                    end
                end
            end
            DRAIN: begin
                array_en_o   = run_en_i;
                busy_o       = 1'b1;
                if (run_en_i) begin
                    cycle_cnt_nxt = cycle_cnt + 1'b1;
                    if(cycle_cnt == (k_size_i + ROW + COL - 2))begin
                        ctrl_state_nxt = DONE;
                        cycle_cnt_nxt = '0;
                    end
                end
            end
            DONE: begin
                done_o = run_en_i;
                cycle_cnt_nxt = '0;
                if (run_en_i) begin
                    ctrl_state_nxt = IDLE;
                end
            end
        endcase
    end
    
    assign feed_cycle_o = cycle_cnt;
endmodule
