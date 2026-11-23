#include <wels/codec_api.h>
#include <iostream>

int main() {
    ISVCEncoder* encoder = nullptr;
    if (WelsCreateSVCEncoder(&encoder) != 0 || !encoder) return 1;
    SEncParamExt params{};
    const auto status = encoder->GetDefaultParams(&params);
    WelsDestroySVCEncoder(encoder);
    if (status != 0 || params.iSpatialLayerNum < 1) return 1;
    const auto version = WelsGetCodecVersion();
    std::cout << version.uMajor << '.' << version.uMinor << '.' << version.uRevision << '\n';
}
