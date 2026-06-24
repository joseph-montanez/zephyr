struct PSInput {
    float4 pos : SV_Position;
    float2 uv : TEXCOORD0;
    float4 color : COLOR;
};

// SDL3 D3D12: pixel-stage sampled textures and samplers MUST be in space2.
Texture2D t_texture : register(t0, space2);
SamplerState s_sampler : register(s0, space2);

float4 main(PSInput input) : SV_Target {
    return t_texture.Sample(s_sampler, input.uv) * input.color;
}
