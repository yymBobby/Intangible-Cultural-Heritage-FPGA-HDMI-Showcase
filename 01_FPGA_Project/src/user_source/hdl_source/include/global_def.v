


`define   DATA_WIDTH                        32
`define   ADDR_WIDTH                        21
`define   DM_WIDTH                          4

`define   ROW_WIDTH                        11
`define   BA_WIDTH                        2

// EM638325 requires 4096 AUTO REFRESH commands per 64 ms, independent
// of the 11-bit application row address. Keep macro arithmetic grouped.
`define   SDR_CLK_PERIOD                 (1000000000/125000000)
`define   SDR_REFRESH_CYCLES              4096
`define   SDR_REFRESH_WINDOW_NS           64000000
// Counter visits 0..terminal inclusive: 1952 means 1953 clocks at 125 MHz.
`define   SELF_REFRESH_INTERVAL          ((`SDR_REFRESH_WINDOW_NS/`SDR_CLK_PERIOD/`SDR_REFRESH_CYCLES)-1)

