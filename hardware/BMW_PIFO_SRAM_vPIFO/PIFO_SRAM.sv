    `timescale 1ns / 10ps
    /*-----------------------------------------------------------------------------

    Proprietary and Confidential Information

    Module: PIFO_SRAM.v
    Author: Zhiyu Zhang
    Date  : 03/10/2023

    Description: Instead of using FFs to implement PIFO, this module uses SRAM
                so that the whole PIFO tree can be extended to more layers. 
                
    Issues:  

    -----------------------------------------------------------------------------*/

    //-----------------------------------------------------------------------------
    // Module Port Definition
    //-----------------------------------------------------------------------------
module PIFO_SRAM 
#(
    parameter PTW    = 16,       // Payload data width
    parameter MTW    = 0,        // Metdata width
    parameter CTW    = 10,       // Counter width
    parameter LEVEL  = 4,         // Sub-tree level
    parameter TREE_NUM = 4,

    localparam LEVEL_BITS       = (LEVEL <= 1) ? 1 : $clog2(LEVEL),
    localparam TREE_NUM_BITS    = (TREE_NUM <= 1) ? 1 : $clog2(TREE_NUM),
    localparam TREE_SIZE_BITS   = LEVEL,
    // One binary LEVEL-level tree occupies 2**LEVEL-1 node addresses.  The
    // rotating placement packs at most ceil(TREE_NUM/LEVEL) such address
    // spans into any RPU SRAM.  Size the uniform SRAM from that proven upper
    // bound instead of adding LEVEL to an incorrectly parenthesized quotient.
    localparam [63:0] TREE_SIZE_VALUE =
        (64'd1 << LEVEL) - 64'd1,
    localparam integer TREE_GROUPS =
        (TREE_NUM + LEVEL - 1) / LEVEL,
    localparam [63:0] SRAM_REQUIRED_DEPTH =
        TREE_GROUPS * TREE_SIZE_VALUE,
    localparam SRAM_ADW =
        (SRAM_REQUIRED_DEPTH <= 1) ? 1 :
        $clog2(SRAM_REQUIRED_DEPTH),
    localparam ADW = (LEVEL <= 1) ? 1 : LEVEL-1,
    localparam [SRAM_ADW-1:0] TREE_STRIDE =
        TREE_SIZE_VALUE[SRAM_ADW-1:0]
)(
    // Clock and Reset
    input                          i_clk,         // I - Clock
    input                          i_arst_n,      // I - Active Low Async Reset
    
    // From/To Parent 
    input                          i_push,        // I - Push Command from Parent
    input  [(MTW+PTW)-1:0]         i_push_data,   // I - Push Data from Parent
    
    input                          i_pop,         // I - Pop Command from Parent
    output [(MTW+PTW)-1:0]         o_pop_data,    // O - Pop Data from Parent
    
    // From/To Child
    output                         o_push,        // O - Push Command to Child
    output [(MTW+PTW)-1:0]         o_push_data,   // O - Push Data to Child
    
    output                         o_pop,         // O - Pop Command to Child   
    input  [(MTW+PTW)-1:0]         i_pop_data,    // I - Pop Data from Child
    
    // From/To SRAM
    output                         o_read,        // O - SRAM Read
    input  [2*(CTW+MTW+PTW)-1:0]   i_read_data,   // I - SRAM Read Data {sub_tree_size3,pifo_val3,sub_tree_size2,pifo_val2,sub_tree_size1,pifo_val1,sub_tree_size0,pifo_val0}
    
    output                         o_write,       // O - SRAM Write
    output [2*(CTW+MTW+PTW)-1:0]   o_write_data,  // O - SRAM Write Data {sub_tree_size3,pifo_val3,sub_tree_size2,pifo_val2,sub_tree_size1,pifo_val1,sub_tree_size0,pifo_val0}

    input[TREE_NUM_BITS-1:0]	   i_tree_id,
    output[TREE_NUM_BITS-1:0]	   o_tree_id,

    input  [ADW-1:0]               i_my_addr,
    output [ADW-1:0]               o_child_addr,

    input [LEVEL_BITS-1:0]      i_level,
    output [LEVEL_BITS-1:0]     o_level,
    output                         o_is_level0_pop,

    // Stable root summary after the root writeback for one physical tree.
    // Push completes in ST_PUSH; Pop's replacement Head is only final in ST_WB.
    output                         o_root_update_valid,
    output [PTW-1:0]               o_root_update_head_rank,

    output [SRAM_ADW-1:0]          o_read_addr,
    output [SRAM_ADW-1:0]          o_write_addr
);

    //-----------------------------------------------------------------------------
    // Include Files
    //-----------------------------------------------------------------------------

    initial begin
        if ((LEVEL < 2) || (LEVEL > 62) || (TREE_NUM < 1))
            $fatal(1, "PIFO_SRAM requires 2 <= LEVEL <= 62 and TREE_NUM >= 1");
    end


    //-----------------------------------------------------------------------------
    // Parameters
    //-----------------------------------------------------------------------------
    localparam  ST_IDLE     = 2'b00,
                ST_PUSH     = 2'b01,
                ST_POP      = 2'b11,
                ST_WB       = 2'b10;

    //-----------------------------------------------------------------------------
    // Register and Wire Declarations
    //-----------------------------------------------------------------------------
    // State Machine
    reg [1:0]             fsm;
    
    // SRAM Read/Write   
    wire                  read;
    reg                   write;
    reg [2*(CTW+MTW+PTW)-1:0] wdata;
    
    // Push to child
    reg                   push;
    reg [(MTW+PTW)-1:0]   push_data;
        
    reg                   pop;
    reg [(MTW+PTW)-1:0]   pop_data;   
        
    reg                   min_sub_tree;
    reg                   min_data_port;
    
    reg [(MTW+PTW)-1:0]   ipushd_latch;

    //for parent/child node
    reg [ADW-1:0]         my_addr;
    reg [ADW-1:0]         child_addr;

    // curent level ie write_level
    reg [LEVEL_BITS-1:0] cur_level;
    reg [TREE_NUM_BITS-1:0] cur_tree_id;
    
    

    
    

        
    //-----------------------------------------------------------------------------
    // Instantiations
    //-----------------------------------------------------------------------------


    //-----------------------------------------------------------------------------
    // Functions and Tasks
    //-----------------------------------------------------------------------------

    //-----------------------------------------------------------------------------
    // Sequential Logic
    //-----------------------------------------------------------------------------
    always @ (posedge i_clk or negedge i_arst_n)
    begin
        if (!i_arst_n) begin
            fsm[1:0]     <= ST_IDLE;
            ipushd_latch <= 'd0;	
            my_addr      <= 'd0;
            cur_level <= '0;
            cur_tree_id <= '0;
        end else begin
            unique case (fsm[1:0])
                ST_IDLE: begin
                unique case ({i_push, i_pop})
                    2'b00,
                    2'b11: begin // Not allow concurrent read and write
                    fsm[1:0]    <= ST_IDLE;
                    ipushd_latch <= 'd0;
                    my_addr      <= 'd0;	
                    cur_level <= '0;	 
                    cur_tree_id <= '0;
                    end
                    2'b01: begin // pop
                        fsm[1:0]    <= ST_POP;
                        ipushd_latch <= 'd0;
                        my_addr      <= i_my_addr;
                        cur_level <= i_level;
                        cur_tree_id <= i_tree_id;	 
                    end
                    2'b10: begin // push
                        fsm[1:0]     <= ST_PUSH;
                        ipushd_latch <= i_push_data;		
                        my_addr      <= i_my_addr; 
                        cur_level <= i_level;
                        cur_tree_id <= i_tree_id;
                    end
                endcase
                end

                ST_PUSH: begin       	
                unique case ({i_push, i_pop})
                    2'b00,
                    2'b11: begin 
                        fsm[1:0]    <= ST_IDLE;
                        ipushd_latch <= 'd0;	
                        my_addr      <= 'd0; 
                        cur_level <= '0;
                        cur_tree_id <= '0;	 
                    end
                    2'b01: begin
                        fsm[1:0]    <= ST_POP;
                        ipushd_latch <= 'd0;		 
                        my_addr      <= i_my_addr;
                        cur_level <= i_level;
                        cur_tree_id <= i_tree_id;
                    end
                    2'b10: begin 
                        fsm[1:0]    <= ST_PUSH;
                        ipushd_latch <= i_push_data;
                        my_addr      <= i_my_addr;
                        cur_level <= i_level;
                        cur_tree_id <= i_tree_id;	 
                    end
                endcase   
                end   

                ST_POP: begin
                ipushd_latch <= ipushd_latch;		
                my_addr      <= my_addr;
                fsm[1:0]     <= ST_WB;
                cur_level <= cur_level;
                cur_tree_id <= cur_tree_id;
                end		
                
                ST_WB: begin		       
                    unique case ({i_push, i_pop})
                    2'b00,
                    2'b11: begin 
                        fsm[1:0]    <= ST_IDLE;
                        ipushd_latch <= 'd0;		
                        my_addr      <= 'd0; 
                        cur_level <= '0;
                        cur_tree_id <= '0;
                    end
                    2'b01: begin
                        fsm[1:0]    <= ST_POP;
                        ipushd_latch <= 'd0;	
                        my_addr      <= i_my_addr;	
                        cur_level <= i_level;
                        cur_tree_id <= i_tree_id;
                    end
                    2'b10: begin 
                        fsm[1:0]    <= ST_PUSH;
                        ipushd_latch <= i_push_data;	
                        my_addr      <= i_my_addr; 
                        cur_level <= i_level;
                        cur_tree_id <= i_tree_id;
                    end
                endcase
                end			
            endcase
        end	  
    end
    
    //-----------------------------------------------------------------------------
    // Combinatorial Logic / Continuous Assignments
    //-----------------------------------------------------------------------------
    logic [SRAM_ADW-1:0] read_offset;
    logic [SRAM_ADW-1:0] write_offset;
    logic [TREE_SIZE_BITS-1:0] read_lo;
    logic [TREE_SIZE_BITS-1:0] write_lo;
    logic [SRAM_ADW-1:0] read_hi_wide;
    logic [SRAM_ADW-1:0] write_hi_wide;
    logic [SRAM_ADW-1:0] read_lo_wide;
    logic [SRAM_ADW-1:0] write_lo_wide;

    assign read_hi_wide =
        SRAM_ADW'(i_tree_id) / SRAM_ADW'(LEVEL);
    assign write_hi_wide =
        SRAM_ADW'(cur_tree_id) / SRAM_ADW'(LEVEL);
    assign read_lo_wide =
        {{(SRAM_ADW-TREE_SIZE_BITS){1'b0}}, read_lo};
    assign write_lo_wide =
        {{(SRAM_ADW-TREE_SIZE_BITS){1'b0}}, write_lo};


    always_comb begin
        read_lo = '0;
        for(int i=0; i<LEVEL-1; ++i)begin
            if(i < (i_tree_id % LEVEL))
                read_lo = (1 << ((i+i_level+1) % LEVEL)) | read_lo;
        end

        read_offset = read_hi_wide * TREE_STRIDE + read_lo_wide;
    end

    always_comb begin
        write_lo = '0;
        for(int i=0; i<LEVEL-1; ++i)begin
            if(i < (cur_tree_id % LEVEL))
                write_lo = (1 << ((i+cur_level+1) % LEVEL)) | write_lo;
        end

        write_offset = write_hi_wide * TREE_STRIDE + write_lo_wide;
    end

    always @ *
    begin
        if (fsm == ST_POP || fsm == ST_WB) begin
            push       = '0;
            push_data  = '0;
            unique case (min_data_port)
                1'b0: begin
                pop           = 1'b1;
                pop_data      = i_read_data[(MTW+PTW)-1:0];
                write         = 1'b1;
                child_addr    = 2 * my_addr + 0;
                if (i_read_data[(MTW+PTW+CTW)-1:(MTW+PTW)] != 0) begin
                    wdata      = {i_read_data[2*(CTW+MTW+PTW)-1:(CTW+MTW+PTW)], i_read_data[(CTW+MTW+PTW)-1:(MTW+PTW)]-{{(CTW-1){1'b0}},1'b1}, i_pop_data};
                end else begin
                    wdata      = i_read_data[2*(CTW+MTW+PTW)-1:0];
                end						   
                end
                1'b1: begin
                pop           = 1'b1;
                pop_data      = i_read_data[2*(MTW+PTW)+CTW-1:(CTW+MTW+PTW)];
                write         = 1'b1;
                child_addr    = 2 * my_addr + 1;
                if (i_read_data[2*(MTW+PTW+CTW)-1:2*(MTW+PTW)+CTW] != 0) begin
                    wdata      = {i_read_data[2*(CTW+MTW+PTW)-1:2*(MTW+PTW)+CTW]-{{(CTW-1){1'b0}},1'b1}, i_pop_data, i_read_data[(MTW+PTW+CTW)-1:0]};
                end else begin
                    wdata      = i_read_data[2*(CTW+MTW+PTW)-1:0];
                end						   
                end
            endcase	  	
        end else if (fsm == ST_PUSH) begin
            pop       = 1'b0;                 
            pop_data  = -'d1;

            unique case (min_sub_tree)

                1'b0: begin // push 0
                write          = 1'b1;
                child_addr     = 2 * my_addr;
                if (i_read_data[PTW-1:0] != {PTW{1'b1}}) begin
                    push       = 1'b1;
                    if (ipushd_latch[(PTW)-1:0] < i_read_data[(PTW)-1:0]) begin
                        push_data = i_read_data[(MTW+PTW)-1:0];
                        wdata     = {i_read_data[2*(MTW+PTW+CTW)-1:(MTW+PTW+CTW)], i_read_data[(MTW+PTW+CTW)-1:(MTW+PTW)]+{{(CTW-1){1'b0}},1'b1}, ipushd_latch};					 
                    end else begin
                        push_data = ipushd_latch;
                        wdata     = {i_read_data[2*(MTW+PTW+CTW)-1:(MTW+PTW+CTW)], i_read_data[(MTW+PTW+CTW)-1:(MTW+PTW)]+{{(CTW-1){1'b0}},1'b1}, i_read_data[(MTW+PTW)-1:0]};					 
                    end						
                end else begin
                    push         = 1'd0;
                    push_data    = 'd0;
                    wdata        = {i_read_data[2*(MTW+PTW+CTW)-1:(MTW+PTW+CTW)], i_read_data[(MTW+PTW+CTW)-1:(MTW+PTW)]+{{(CTW-1){1'b0}},1'b1}, ipushd_latch};					 
                end
                end

                1'b1: begin // push 1
                write           = 1'b1;
                child_addr      = 2 * my_addr + 1;
                if (i_read_data[2*PTW+(MTW+CTW)-1:(MTW+PTW+CTW)] != {PTW{1'b1}}) begin
                    push         = 1'b1;
                    if (ipushd_latch[(PTW)-1:0] < i_read_data[2*PTW+MTW+CTW-1:(MTW+PTW+CTW)]) begin
                        push_data = i_read_data[(2*(MTW+PTW)+CTW)-1:(CTW+MTW+PTW)];
                        wdata     = {i_read_data[2*(CTW+MTW+PTW)-1:2*(MTW+PTW)+CTW]+{{(CTW-1){1'b0}},1'b1}, ipushd_latch, i_read_data[(CTW+MTW+PTW)-1:0]};
                    end else begin
                        push_data = ipushd_latch;
                        wdata     = {i_read_data[2*(CTW+MTW+PTW)-1:2*(MTW+PTW)+CTW]+{{(CTW-1){1'b0}},1'b1}, i_read_data[2*(MTW+PTW)+CTW-1:0]};
                    end
                end else begin
                    push         = 1'd0;
                    push_data    = 'd0;
                    wdata        = {i_read_data[2*(CTW+MTW+PTW)-1:2*(MTW+PTW)+CTW]+{{(CTW-1){1'b0}},1'b1}, ipushd_latch, i_read_data[(CTW+MTW+PTW)-1:0]};
                end
                end
            endcase		
        end else begin
            push        = 1'd0;
            push_data   = 'd0;
            write       = 1'b0;
            wdata       = 'd0;         
            pop         = 1'b0;                 
            pop_data    = -'d1;
            child_addr  = -'d1;
        end	  
    end
    
    always @ *
    begin
        // Find the minimum sub-tree. 
        if (i_read_data[(CTW+MTW+PTW)-1:(MTW+PTW)] <= i_read_data[2*(CTW+MTW+PTW)-1:2*(MTW+PTW)+CTW]) begin
            min_sub_tree = 1'b0;	  
        end else begin
            min_sub_tree = 1'b1;
        end		 
        
        // Find the minimum data and minimum data port.
        if (i_read_data[PTW-1:0] <= i_read_data[2*PTW+(CTW+MTW)-1:(CTW+MTW+PTW)]) begin
            min_data_port  = 1'b0;
        end else begin
            min_data_port  = 1'b1;
        end		 		  	  
    end

    //-----------------------------------------------------------------------------
    // Continous Assignments
    //-----------------------------------------------------------------------------
    assign read = (i_push | i_pop) & (fsm == ST_IDLE | fsm == ST_WB | fsm == ST_PUSH);
    
    
        
    //-----------------------------------------------------------------------------
    // Output Assignments
    //-----------------------------------------------------------------------------
    assign o_read_addr   = read_offset +
        {{(SRAM_ADW-ADW){1'b0}}, i_my_addr};
    assign o_write_addr  = write_offset +
        {{(SRAM_ADW-ADW){1'b0}}, my_addr};

    assign o_read        = read;
    assign o_write       = write;
    assign o_write_data  = wdata;
    
    assign o_push        = cur_level < LEVEL-1  ? push : '0;
    assign o_push_data   = push_data;
    assign o_pop         = cur_level < LEVEL-1  ? pop : '0;
    
    assign o_pop_data    = pop_data;
    assign o_child_addr  = child_addr;

    assign o_level = cur_level + 1;
    assign o_is_level0_pop = (cur_level == 0) && (fsm == ST_POP);

    assign o_root_update_valid = (cur_level == 0) &&
                                 ((fsm == ST_PUSH) || (fsm == ST_WB));
    assign o_root_update_head_rank =
        (wdata[PTW-1:0] <=
         wdata[(CTW+MTW+PTW)+PTW-1:(CTW+MTW+PTW)]) ?
        wdata[PTW-1:0] :
        wdata[(CTW+MTW+PTW)+PTW-1:(CTW+MTW+PTW)];

    assign o_tree_id = cur_tree_id; // treeid

endmodule
