# Creates the Xilinx IP cores used by the design (sourced by build.tcl).
# PCIe: XDMA, Gen3 x16, AXI-Lite master on BAR0 (1 MB) -- the host register window.
create_ip -name xdma -vendor xilinx.com -library ip -module_name xdma_0 -dir $ip_dir
set_property -dict [list \
    CONFIG.mode_selection          {Advanced} \
    CONFIG.pl_link_cap_max_link_width {X16} \
    CONFIG.pl_link_cap_max_link_speed {8.0_GT/s} \
    CONFIG.axi_data_width          {512_bit} \
    CONFIG.axisten_freq            {250} \
    CONFIG.pf0_device_id           {903F} \
    CONFIG.pf0_class_code_base     {12} \
    CONFIG.pf0_class_code_sub      {00} \
    CONFIG.pf0_class_code_interface {00} \
    CONFIG.axilite_master_en       {true} \
    CONFIG.axilite_master_size     {1} \
    CONFIG.axilite_master_scale    {Megabytes} \
    CONFIG.xdma_rnum_chnl          {1} \
    CONFIG.xdma_wnum_chnl          {1} \
    CONFIG.xdma_axi_intf_mm        {AXI_Memory_Mapped} \
    CONFIG.pf0_msix_enabled        {false} \
    CONFIG.plltype                 {QPLL1} \
    CONFIG.pcie_blk_locn           {PCIE4C_X1Y0} \
    CONFIG.select_quad             {GTY_Quad_227} \
] [get_ips xdma_0]

# Flash controller: layout expected by AMD xbflash2 (quad, Micron, 256-deep FIFO,
# AXI4-Lite, no XIP, STARTUPE3 inside the core). In quad mode the SCK ratio is
# fixed at 2: SCK = ext_spi_clk / 2.
create_ip -name axi_quad_spi -vendor xilinx.com -library ip -module_name qspi_0 -dir $ip_dir
set_property -dict [list \
    CONFIG.C_SPI_MEMORY            {2} \
    CONFIG.C_SPI_MODE              {2} \
    CONFIG.C_FIFO_DEPTH            {256} \
    CONFIG.C_NUM_SS_BITS           {1} \
    CONFIG.C_USE_STARTUP           {1} \
    CONFIG.C_USE_STARTUP_INT       {1} \
    CONFIG.C_XIP_MODE              {0} \
    CONFIG.C_TYPE_OF_AXI4_INTERFACE {0} \
] [get_ips qspi_0]
