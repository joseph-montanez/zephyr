struct VSInput {
    float2 pos : TEXCOORD0;
    float4 color : TEXCOORD1;
    uint entityIndex : TEXCOORD2;
    float2 uv : TEXCOORD3;
};

struct VSOutput {
    float4 pos : SV_Position;
    float4 color : COLOR;
    uint entityIndex : TEXCOORD2;
};

cbuffer CameraUniform : register(b0, space1) {
    float4x4 u_matrix;
};

VSOutput main(VSInput input) {
    VSOutput output;
    output.pos = mul(u_matrix, float4(input.pos, 0.0, 1.0));
    output.color = input.color;
    output.entityIndex = input.entityIndex;
    return output;
}
