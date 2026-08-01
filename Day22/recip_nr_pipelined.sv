// =============================================================================
// Day22 : Fully-Pipelined Newton-Raphson Fixed-Point Reciprocal Unit  (1 / x)
// -----------------------------------------------------------------------------
// A hardware reciprocal engine -- the GPU Special-Function-Unit primitive
// (`MUFU.RCP` / `__frcp_rn`) and the workhorse of ultra-low-latency HFT /
// FPGA datapaths, where division (VWAP, price ratios, book-imbalance, implied
// vol, per-share normalisation) is the expensive operation. Division is turned
// into a *fixed-latency, one-result-per-cycle* stream of shifts, adds and a
// handful of DSP multiplies -- no iterative divider, no data-dependent latency.
//
// ALGORITHM (range-reduced Newton-Raphson):
//   1. NORMALISE : leading-zero-count barrel-shift the unsigned input X so its
//                  MSB sits at bit W-1, giving a mantissa  m in [1, 2)  plus a
//                  shift amount s  (X = m * 2^(W-1-s)).
//   2. SEED      : an  8-bit-indexed ROM returns  y0 ~= 1/m  (>=8 good bits).
//   3. REFINE    : two Newton-Raphson steps  y <- y*(2 - m*y)  -- each step
//                  roughly DOUBLES the number of correct bits (8 -> 16 -> 32),
//                  so 2 iterations give a >=24-bit-accurate reciprocal.
//   4. DENORMALISE: shift the mantissa reciprocal back by the exponent to form
//                  the Q-scaled result  Y ~= round(2^SCALE / X),  SCALE=2(W-1).
//
// Every step is a single registered pipeline stage => LATENCY = 7 cycles,
// throughput = 1 reciprocal / cycle, latency fully data-INDEPENDENT (identical
// for every operand -- the property HFT tick-to-trade paths are built around).
//
// Multiplier-based (4 DSP multiplies) by nature -- reciprocal is a multiply
// problem; the shifts/LZC map to FPGA fabric, the mults to DSP48 / DSP58 slices.
//
// Interface (all synchronous, active-low reset):
//   in_valid,  x[W-1:0]              -> launch a reciprocal
//   out_valid, y[OW-1:0]  (7 cyc later) -> Y = round(2^SCALE / x),  SCALE=2*(W-1)
//   x must be non-zero (1..2^W-1); x==0 is flagged on div0 (result saturates).
//
// Self-checking TB (tb_recip_nr_pipelined.sv) compares every result against an
// INDEPENDENT integer golden  round(2^SCALE / x)  (real division, not the NR
// datapath) over directed corners + thousands of random operands.
// =============================================================================
`timescale 1ns/1ps

module recip_nr_pipelined #(
    parameter int W  = 24                    // input width (x is unsigned 1..2^W-1)
)(
    input  logic                 clk,
    input  logic                 rst_n,
    input  logic                 in_valid,
    input  logic [W-1:0]         x,
    output logic                 out_valid,
    output logic                 div0,        // asserted with out_valid when x==0
    output logic [(2*(W-1)):0]   y            // Q-scaled reciprocal, OW = 2W-1 bits
);
    localparam int IF    = 40;                // internal fractional bits (Q1.40 mantissa)
    localparam int LB    = 8;                 // seed-ROM index bits
    localparam int NL    = 1 << LB;           // 256 ROM entries
    localparam int SCALE = 2*(W-1);           // output scale exponent (=46 for W=24)
    localparam int OW    = SCALE + 1;          // output width (=47 for W=24)
    localparam int MW    = IF + 1;            // mantissa width (=41): 1 int + IF frac

    // ---- signed shift amount fits in a small signed field ----
    localparam int SHW   = 8;                 // signed denorm-shift width

    // ============================ Seed ROM ===================================
    // seed[idx] ~= (1/m) * 2^IF  for m = 1 + (idx+0.5)/NL,  MW-bit unsigned.
    logic [MW-1:0] seed [0:NL-1];
    initial begin
      seed[0]=41'h0ff803fe010;
      seed[1]=41'h0fe823ca508;
      seed[2]=41'h0fd863086af;
      seed[3]=41'h0fc8c15b40a;
      seed[4]=41'h0fb93e672fb;
      seed[5]=41'h0fa9d9d1fd1;
      seed[6]=41'h0f9a9342cdc;
      seed[7]=41'h0f8b6a62201;
      seed[8]=41'h0f7c5ed9c4f;
      seed[9]=41'h0f6d7054d9f;
      seed[10]=41'h0f5e9e7fc28;
      seed[11]=41'h0f4fe908227;
      seed[12]=41'h0f414f9cd78;
      seed[13]=41'h0f32d1edf3a;
      seed[14]=41'h0f246facb7a;
      seed[15]=41'h0f16288b8cf;
      seed[16]=41'h0f07fc3e00f;
      seed[17]=41'h0ef9ea78bef;
      seed[18]=41'h0eebf2f18b7;
      seed[19]=41'h0ede155f3ec;
      seed[20]=41'h0ed05179c02;
      seed[21]=41'h0ec2a6fa00f;
      seed[22]=41'h0eb51599f7c;
      seed[23]=41'h0ea79d149bb;
      seed[24]=41'h0e9a3d25e01;
      seed[25]=41'h0e8cf58aaf8;
      seed[26]=41'h0e7fc600e80;
      seed[27]=41'h0e72ae47564;
      seed[28]=41'h0e65ae1db1b;
      seed[29]=41'h0e58c544987;
      seed[30]=41'h0e4bf37d8af;
      seed[31]=41'h0e3f388ae86;
      seed[32]=41'h0e32942feab;
      seed[33]=41'h0e260630a2b;
      seed[34]=41'h0e198e51f49;
      seed[35]=41'h0e0d2c59940;
      seed[36]=41'h0e00e00e00e;
      seed[37]=41'h0df4a93683b;
      seed[38]=41'h0de8879b2a3;
      seed[39]=41'h0ddc7b04c3d;
      seed[40]=41'h0dd0833cdec;
      seed[41]=41'h0dc4a00dc4a;
      seed[42]=41'h0db8d142773;
      seed[43]=41'h0dad16a6ad8;
      seed[44]=41'h0da17006d0c;
      seed[45]=41'h0d95dd2ff93;
      seed[46]=41'h0d8a5defebb;
      seed[47]=41'h0d7ef215166;
      seed[48]=41'h0d73996e8e1;
      seed[49]=41'h0d6853cc0bc;
      seed[50]=41'h0d5d20fde97;
      seed[51]=41'h0d5200d5201;
      seed[52]=41'h0d46f323447;
      seed[53]=41'h0d3bf7ba853;
      seed[54]=41'h0d310e6da7c;
      seed[55]=41'h0d263710069;
      seed[56]=41'h0d1b71758e2;
      seed[57]=41'h0d10bd72bb0;
      seed[58]=41'h0d061adc976;
      seed[59]=41'h0cfb8988b90;
      seed[60]=41'h0cf1094d3eb;
      seed[61]=41'h0ce69a00ce7;
      seed[62]=41'h0cdc3b7a931;
      seed[63]=41'h0cd1ed923a8;
      seed[64]=41'h0cc7b01ff34;
      seed[65]=41'h0cbd82fc6ab;
      seed[66]=41'h0cb36600cb3;
      seed[67]=41'h0ca95906b9f;
      seed[68]=41'h0c9f5be8553;
      seed[69]=41'h0c956e80325;
      seed[70]=41'h0c8b90a95c2;
      seed[71]=41'h0c81c23f50e;
      seed[72]=41'h0c78031e00c;
      seed[73]=41'h0c6e5321cbf;
      seed[74]=41'h0c64b22780f;
      seed[75]=41'h0c5b200c5b2;
      seed[76]=41'h0c519cae00c;
      seed[77]=41'h0c4827ea81c;
      seed[78]=41'h0c3ec1a055b;
      seed[79]=41'h0c3569ae5ad;
      seed[80]=41'h0c2c1ff3d3e;
      seed[81]=41'h0c22e450673;
      seed[82]=41'h0c19b6a41cc;
      seed[83]=41'h0c1096cf5d2;
      seed[84]=41'h0c0784b2efd;
      seed[85]=41'h0bfe802ffa0;
      seed[86]=41'h0bf58927fd0;
      seed[87]=41'h0bec9f7cd52;
      seed[88]=41'h0be3c310b85;
      seed[89]=41'h0bdaf3c634a;
      seed[90]=41'h0bd231802f5;
      seed[91]=41'h0bc97c21e34;
      seed[92]=41'h0bc0d38ee01;
      seed[93]=41'h0bb837ab087;
      seed[94]=41'h0bafa85a916;
      seed[95]=41'h0ba7258200c;
      seed[96]=41'h0b9eaf062c5;
      seed[97]=41'h0b9644cc388;
      seed[98]=41'h0b8de6b9975;
      seed[99]=41'h0b8594b4073;
      seed[100]=41'h0b7d4ea1922;
      seed[101]=41'h0b7514688c6;
      seed[102]=41'h0b6ce5ef937;
      seed[103]=41'h0b64c31d8d6;
      seed[104]=41'h0b5cabd9a74;
      seed[105]=41'h0b54a00b54a;
      seed[106]=41'h0b4c9f9a4e6;
      seed[107]=41'h0b44aa6e91d;
      seed[108]=41'h0b3cc0705f8;
      seed[109]=41'h0b34e1883ad;
      seed[110]=41'h0b2d0d9ee8a;
      seed[111]=41'h0b25449d6e7;
      seed[112]=41'h0b1d866d11b;
      seed[113]=41'h0b15d2f756f;
      seed[114]=41'h0b0e2a2600b;
      seed[115]=41'h0b068be30ed;
      seed[116]=41'h0afef818bdb;
      seed[117]=41'h0af76eb1855;
      seed[118]=41'h0aefef9818a;
      seed[119]=41'h0ae87ab7649;
      seed[120]=41'h0ae10ffa8f8;
      seed[121]=41'h0ad9af4cf83;
      seed[122]=41'h0ad2589a357;
      seed[123]=41'h0acb0bce14f;
      seed[124]=41'h0ac3c8d49ac;
      seed[125]=41'h0abc8f9a00b;
      seed[126]=41'h0ab5600ab56;
      seed[127]=41'h0aae3a135bd;
      seed[128]=41'h0aa71da0ca6;
      seed[129]=41'h0aa00aa00aa;
      seed[130]=41'h0a9900fe581;
      seed[131]=41'h0a9200a9201;
      seed[132]=41'h0a8b098e00b;
      seed[133]=41'h0a841b9ac87;
      seed[134]=41'h0a7d36bd75b;
      seed[135]=41'h0a765ae435a;
      seed[136]=41'h0a6f87fd642;
      seed[137]=41'h0a68bdf78ae;
      seed[138]=41'h0a61fcc1610;
      seed[139]=41'h0a5b4449ca4;
      seed[140]=41'h0a54947fd6b;
      seed[141]=41'h0a4ded52c1e;
      seed[142]=41'h0a474eb1f28;
      seed[143]=41'h0a40b88cf9f;
      seed[144]=41'h0a3a2ad3935;
      seed[145]=41'h0a33a575a39;
      seed[146]=41'h0a2d2863385;
      seed[147]=41'h0a26b38c87c;
      seed[148]=41'h0a2046e1f03;
      seed[149]=41'h0a19e253f73;
      seed[150]=41'h0a1385d3496;
      seed[151]=41'h0a0d3150b9f;
      seed[152]=41'h0a06e4bd422;
      seed[153]=41'h0a00a00a00a;
      seed[154]=41'h09fa6328396;
      seed[155]=41'h09f42e0954f;
      seed[156]=41'h09ee009ee01;
      seed[157]=41'h09e7dada8b5;
      seed[158]=41'h09e1bcae2aa;
      seed[159]=41'h09dba60bb4d;
      seed[160]=41'h09d596e5435;
      seed[161]=41'h09cf8f2d118;
      seed[162]=41'h09c98ed57c8;
      seed[163]=41'h09c395d102c;
      seed[164]=41'h09bda412439;
      seed[165]=41'h09b7b98bfed;
      seed[166]=41'h09b1d631145;
      seed[167]=41'h09abf9f483c;
      seed[168]=41'h09a624c96c4;
      seed[169]=41'h09a056a30bc;
      seed[170]=41'h099a8f74bee;
      seed[171]=41'h0994cf3200a;
      seed[172]=41'h098f15ce69c;
      seed[173]=41'h0989633db0c;
      seed[174]=41'h0983b773a93;
      seed[175]=41'h097e126443a;
      seed[176]=41'h097874038d3;
      seed[177]=41'h0972dc45af2;
      seed[178]=41'h096d4b1eeea;
      seed[179]=41'h0967c083ac8;
      seed[180]=41'h09623c6864e;
      seed[181]=41'h095cbec1aeb;
      seed[182]=41'h095747843b9;
      seed[183]=41'h0951d6a4d78;
      seed[184]=41'h094c6c1868a;
      seed[185]=41'h094707d3eea;
      seed[186]=41'h0941a9cc82c;
      seed[187]=41'h093c51f7577;
      seed[188]=41'h09370049b80;
      seed[189]=41'h0931b4b9085;
      seed[190]=41'h092c6f3ac4b;
      seed[191]=41'h09272fc4815;
      seed[192]=41'h0921f64bea5;
      seed[193]=41'h091cc2c6c36;
      seed[194]=41'h0917952ae74;
      seed[195]=41'h09126d6e480;
      seed[196]=41'h090d4b86ee3;
      seed[197]=41'h09082f6af8f;
      seed[198]=41'h090319109db;
      seed[199]=41'h08fe086e27e;
      seed[200]=41'h08f8fd79f8b;
      seed[201]=41'h08f3f82a86e;
      seed[202]=41'h08eef8765e6;
      seed[203]=41'h08e9fe54205;
      seed[204]=41'h08e509ba82a;
      seed[205]=41'h08e01aa04fe;
      seed[206]=41'h08db30fc66f;
      seed[207]=41'h08d64cc5baf;
      seed[208]=41'h08d16df352f;
      seed[209]=41'h08cc947c49b;
      seed[210]=41'h08c7c057cd8;
      seed[211]=41'h08c2f17d201;
      seed[212]=41'h08be27e3960;
      seed[213]=41'h08b96382971;
      seed[214]=41'h08b4a4519d8;
      seed[215]=41'h08afea48365;
      seed[216]=41'h08ab355e009;
      seed[217]=41'h08a6858aad9;
      seed[218]=41'h08a1dac6009;
      seed[219]=41'h089d3507ce8;
      seed[220]=41'h08989447fde;
      seed[221]=41'h0893f87e869;
      seed[222]=41'h088f61a371b;
      seed[223]=41'h088acfaed95;
      seed[224]=41'h08864298e85;
      seed[225]=41'h0881ba59da4;
      seed[226]=41'h087d36e9fb4;
      seed[227]=41'h0878b841a79;
      seed[228]=41'h08743e594bd;
      seed[229]=41'h086fc929647;
      seed[230]=41'h086b58aa7dc;
      seed[231]=41'h0866ecd533c;
      seed[232]=41'h086285a231d;
      seed[233]=41'h085e230a32c;
      seed[234]=41'h0859c506008;
      seed[235]=41'h08556b8e742;
      seed[236]=41'h0851169c758;
      seed[237]=41'h084cc628fb1;
      seed[238]=41'h08487a2d0a2;
      seed[239]=41'h084432a1b62;
      seed[240]=41'h083fef80210;
      seed[241]=41'h083bb0c17ac;
      seed[242]=41'h0837765f015;
      seed[243]=41'h08334052008;
      seed[244]=41'h082f0e93d1f;
      seed[245]=41'h082ae11ddcc;
      seed[246]=41'h0826b7e9958;
      seed[247]=41'h082292f07e1;
      seed[248]=41'h081e722c259;
      seed[249]=41'h081a5596280;
      seed[250]=41'h08163d282e8;
      seed[251]=41'h081228dbeee;
      seed[252]=41'h080e18ab2b9;
      seed[253]=41'h080a0c8fb3a;
      seed[254]=41'h08060483629;
      seed[255]=41'h08020080201;
    end

    // ======================= Stage 1 : NORMALISE =============================
    // Leading-zero-based normalisation: find s so (x<<s) has bit W-1 set.
    // Combinational priority pick, then barrel-shift.
    function automatic [SHW-1:0] lzc_shift(input logic [W-1:0] v);
        integer i, s;
        logic found;
        begin
            s = 0;
            found = 1'b0;
            // scan from MSB down; s = (W-1) - (index of highest set bit)
            for (i = W-1; i >= 0; i = i - 1) begin
                if (v[i] && !found) begin
                    s = (W-1) - i;
                    found = 1'b1;
                end
            end
            lzc_shift = s;
        end
    endfunction

    logic                 v1;
    logic [MW-1:0]        m1;        // m * 2^IF, in [2^IF, 2^(IF+1))
    logic signed [SHW:0]  sh1;       // denorm shift = s + (W-1) - IF
    logic [LB-1:0]        idx1;
    logic                 z1;        // input-was-zero flag

    // combinational feeds into the stage-1 register (declared before use)
    logic [MW-1:0]        m1_c;
    logic [LB-1:0]        idx1_c;
    logic signed [SHW:0]  sh1_c;
    logic                 z1_c;

    always_comb begin
        logic [SHW-1:0] s;
        logic [W-1:0]   M;           // normalised W-bit mantissa (MSB set)
        s = lzc_shift(x);
        M = x << s;                  // exact: 2^(W-1) <= M < 2^W  (for x!=0)
        // m*2^IF = M << (IF-(W-1)); mantissa fraction top LB bits index the ROM
        m1_c   = {M, {(IF-(W-1)){1'b0}}};
        idx1_c = (M >> (W-1-LB));    // bits [W-2 : W-1-LB] = top LB fraction bits
        sh1_c  = $signed({1'b0, s}) + (W-1) - IF;
        z1_c   = in_valid && (x == '0);   // div-by-zero only for real launches
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin v1<=1'b0; m1<='0; sh1<='0; idx1<='0; z1<=1'b0; end
        else begin
            v1   <= in_valid;
            m1   <= m1_c;
            sh1  <= sh1_c;
            idx1 <= idx1_c;
            z1   <= z1_c;
        end
    end

    // ======================= Stage 2 : SEED ==================================
    logic                 v2;
    logic [MW-1:0]        m2, y2;
    logic signed [SHW:0]  sh2;
    logic                 z2;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin v2<=1'b0; m2<='0; y2<='0; sh2<='0; z2<=1'b0; end
        else begin
            v2  <= v1;
            m2  <= m1;
            y2  <= seed[idx1];
            sh2 <= sh1;
            z2  <= z1;
        end
    end

    // ============ Newton-Raphson step helper : t = 2 - m*y  (Q1.IF) ==========
    // m,y are MW-bit (Q1.IF). product is 2*MW bits (Q2.2IF); >>IF -> Q2.IF.
    localparam logic [IF+1:0] TWO_IF = (1 << (IF+1));   // 2.0 in Q?.IF

    function automatic [IF+1:0] nr_two_minus(input logic [MW-1:0] m,
                                             input logic [MW-1:0] yv);
        logic [2*MW-1:0] prod;
        logic [IF+1:0]   p_if;
        begin
            prod        = m * yv;                 // (m*y) * 2^(2IF)
            p_if        = prod[IF +: (IF+2)];     // >> IF, keep IF+2 bits (Q2.IF)
            nr_two_minus= TWO_IF - p_if;          // (2 - m*y) * 2^IF
        end
    endfunction

    // y_next = y * t  (Q1.IF * Q2.IF = Q3.2IF ; >>IF -> Q3.IF, fits MW+? -> keep MW)
    function automatic [MW-1:0] nr_mul(input logic [MW-1:0] yv,
                                       input logic [IF+1:0] t);
        logic [MW+IF+1:0] prod;
        begin
            prod   = yv * t;                      // (y*t)*2^(2IF)
            nr_mul = prod[IF +: MW];              // >> IF, truncate to MW bits
        end
    endfunction

    // ======================= Stage 3 : NR1 (m*y, 2-p) ========================
    logic                 v3, z3;
    logic [MW-1:0]        m3, y3;
    logic [IF+1:0]        t3;
    logic signed [SHW:0]  sh3;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin v3<=1'b0; m3<='0; y3<='0; t3<='0; sh3<='0; z3<=1'b0; end
        else begin
            v3  <= v2;
            m3  <= m2;
            y3  <= y2;
            t3  <= nr_two_minus(m2, y2);
            sh3 <= sh2;
            z3  <= z2;
        end
    end

    // ======================= Stage 4 : NR1 (y*t) =============================
    logic                 v4, z4;
    logic [MW-1:0]        m4, y4;
    logic signed [SHW:0]  sh4;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin v4<=1'b0; m4<='0; y4<='0; sh4<='0; z4<=1'b0; end
        else begin
            v4  <= v3;
            m4  <= m3;
            y4  <= nr_mul(y3, t3);
            sh4 <= sh3;
            z4  <= z3;
        end
    end

    // ======================= Stage 5 : NR2 (m*y, 2-p) ========================
    logic                 v5, z5;
    logic [MW-1:0]        y5;
    logic [IF+1:0]        t5;
    logic signed [SHW:0]  sh5;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin v5<=1'b0; y5<='0; t5<='0; sh5<='0; z5<=1'b0; end
        else begin
            v5  <= v4;
            y5  <= y4;
            t5  <= nr_two_minus(m4, y4);
            sh5 <= sh4;
            z5  <= z4;
        end
    end

    // ======================= Stage 6 : NR2 (y*t) =============================
    logic                 v6, z6;
    logic [MW-1:0]        y6;
    logic signed [SHW:0]  sh6;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin v6<=1'b0; y6<='0; sh6<='0; z6<=1'b0; end
        else begin
            v6  <= v5;
            y6  <= nr_mul(y5, t5);
            sh6 <= sh5;
            z6  <= z5;
        end
    end

    // ======================= Stage 7 : DENORMALISE ===========================
    // Y = y6 shifted by sh6 (signed). sh6>=0 -> left shift; sh6<0 -> rounded
    // right shift. On div-by-zero saturate to all-ones.
    logic [OW-1:0] y_denorm;
    always_comb begin
        integer r;
        if (sh6 >= 0) begin
            y_denorm = {{(OW-MW){1'b0}}, y6} << sh6;
        end else begin
            r = -sh6;
            // round-to-nearest: add half-ULP before the right shift
            y_denorm = ( ({{(OW-MW){1'b0}}, y6}) + ({{(OW-1){1'b0}},1'b1} << (r-1)) ) >> r;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin out_valid<=1'b0; y<='0; div0<=1'b0; end
        else begin
            out_valid <= v6;
            div0      <= z6;
            y         <= z6 ? {OW{1'b1}} : y_denorm;   // saturate on x==0
        end
    end

endmodule
