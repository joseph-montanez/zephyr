struct PSInput {
    float4 pos : SV_Position;
    float4 color : COLOR;
    uint entityIndex : TEXCOORD2;
};

uint main(PSInput input) : SV_Target {
    return input.entityIndex;
}
