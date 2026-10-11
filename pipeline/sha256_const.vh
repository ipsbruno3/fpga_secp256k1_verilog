// SHA-256 constants (K[0..63] and initial H[0..7])
localparam [255:0] H0 = {
  32'h6a09e667, 32'hbb67ae85, 32'h3c6ef372, 32'ha54ff53a,
  32'h510e527f, 32'h9b05688c, 32'h1f83d9ab, 32'h5be0cd19
};
// not used as concat; H used as array below
reg [31:0] HK [0:7];
initial begin
  HK[0] = 32'h6a09e667;
  HK[1] = 32'hbb67ae85;
  HK[2] = 32'h3c6ef372;
  HK[3] = 32'ha54ff53a;
  HK[4] = 32'h510e527f;
  HK[5] = 32'h9b05688c;
  HK[6] = 32'h1f83d9ab;
  HK[7] = 32'h5be0cd19;
end
reg [31:0] KT [0:63];
initial begin
  KT[0] = 32'h428a2f98;
  KT[1] = 32'h71374491;
  KT[2] = 32'hb5c0fbcf;
  KT[3] = 32'he9b5dba5;
  KT[4] = 32'h3956c25b;
  KT[5] = 32'h59f111f1;
  KT[6] = 32'h923f82a4;
  KT[7] = 32'hab1c5ed5;
  KT[8] = 32'hd807aa98;
  KT[9] = 32'h12835b01;
  KT[10] = 32'h243185be;
  KT[11] = 32'h550c7dc3;
  KT[12] = 32'h72be5d74;
  KT[13] = 32'h80deb1fe;
  KT[14] = 32'h9bdc06a7;
  KT[15] = 32'hc19bf174;
  KT[16] = 32'he49b69c1;
  KT[17] = 32'hefbe4786;
  KT[18] = 32'h0fc19dc6;
  KT[19] = 32'h240ca1cc;
  KT[20] = 32'h2de92c6f;
  KT[21] = 32'h4a7484aa;
  KT[22] = 32'h5cb0a9dc;
  KT[23] = 32'h76f988da;
  KT[24] = 32'h983e5152;
  KT[25] = 32'ha831c66d;
  KT[26] = 32'hb00327c8;
  KT[27] = 32'hbf597fc7;
  KT[28] = 32'hc6e00bf3;
  KT[29] = 32'hd5a79147;
  KT[30] = 32'h06ca6351;
  KT[31] = 32'h14292967;
  KT[32] = 32'h27b70a85;
  KT[33] = 32'h2e1b2138;
  KT[34] = 32'h4d2c6dfc;
  KT[35] = 32'h53380d13;
  KT[36] = 32'h650a7354;
  KT[37] = 32'h766a0abb;
  KT[38] = 32'h81c2c92e;
  KT[39] = 32'h92722c85;
  KT[40] = 32'ha2bfe8a1;
  KT[41] = 32'ha81a664b;
  KT[42] = 32'hc24b8b70;
  KT[43] = 32'hc76c51a3;
  KT[44] = 32'hd192e819;
  KT[45] = 32'hd6990624;
  KT[46] = 32'hf40e3585;
  KT[47] = 32'h106aa070;
  KT[48] = 32'h19a4c116;
  KT[49] = 32'h1e376c08;
  KT[50] = 32'h2748774c;
  KT[51] = 32'h34b0bcb5;
  KT[52] = 32'h391c0cb3;
  KT[53] = 32'h4ed8aa4a;
  KT[54] = 32'h5b9cca4f;
  KT[55] = 32'h682e6ff3;
  KT[56] = 32'h748f82ee;
  KT[57] = 32'h78a5636f;
  KT[58] = 32'h84c87814;
  KT[59] = 32'h8cc70208;
  KT[60] = 32'h90befffa;
  KT[61] = 32'ha4506ceb;
  KT[62] = 32'hbef9a3f7;
  KT[63] = 32'hc67178f2;
end
