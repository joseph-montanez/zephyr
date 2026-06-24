struct PSInput
{
    float4 pos : SV_Position;
    float4 color : COLOR;
    float2 uv : TEXCOORD1;
};

float4 main(PSInput input) : SV_Target0
{
    float4 color = input.color;
    float v = input.uv.y;

    float aa = 1.0;
    if (abs(v) > 0.001) {
        float edgeDist = 1.0 - abs(v);
        float deriv = abs(ddx(v)) + abs(ddy(v));
        float pixelDist = deriv > 0.0 ? edgeDist / deriv : edgeDist * 100.0;
        aa = saturate(pixelDist);
    }

    return float4(color.rgb, color.a * aa);
}
