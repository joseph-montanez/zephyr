struct VSInput {
    float2 pos : TEXCOORD0;
    float4 color : TEXCOORD1;
    uint entityIndex : TEXCOORD2;
};

struct VSOutput {
    float4 pos : SV_Position;
    float4 color : COLOR;
    float2 uv : TEXCOORD1;
};

// SDL3 D3D12: vertex-stage uniform buffers MUST be in space1.
cbuffer CameraUniform : register(b0, space1) {
    float4x4 u_matrix;
    uint hiddenHandleCount;
    uint3 hiddenPadding;
    uint4 hiddenHandles[4]; // 16 hidden entities max
};

// SDL3 D3D12: vertex-stage storage buffers live in space0 (t-registers),
// after any sampled/storage textures. With none of those, this is t0.
StructuredBuffer<float2> uvData : register(t0, space0);

VSOutput main(VSInput input, uint vid : SV_VertexID) {
    VSOutput output;
    
    bool isHidden = false;
    for (uint i = 0; i < hiddenHandleCount; ++i) {
        if (input.entityIndex == hiddenHandles[i / 4][i % 4]) {
            isHidden = true;
            break;
        }
    }
    
    if (isHidden) {
        output.pos = float4(2.0, 2.0, 2.0, 1.0); // Outside clip space
        output.color = input.color;
        output.uv = uvData[vid];
    } else {
        output.pos = mul(u_matrix, float4(input.pos, 0.0, 1.0));
        output.color = input.color;
        output.uv = uvData[vid];
    }
    return output;
}
