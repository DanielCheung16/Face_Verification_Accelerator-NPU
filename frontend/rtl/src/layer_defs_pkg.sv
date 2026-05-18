package layer_defs_pkg;
    typedef enum logic [2:0] {
        LY_NOP       = 3'd0,
        LY_CONV1X1   = 3'd1,
        LY_DWCONV3X3 = 3'd2,
        LY_POOL      = 3'd3,
        LY_FC        = 3'd4,
        LY_CONV3X3   = 3'd5
    } layer_type_t;

    typedef enum logic [1:0] {
        MODE_REQUANT  = 2'd0,
        MODE_PRELU    = 2'd1,
        MODE_RESIDUAL = 2'd2
    } postprocess_mode_t;
endpackage
