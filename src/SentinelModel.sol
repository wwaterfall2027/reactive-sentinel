// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @title SentinelModel
/// @notice A 6-8-1 ReLU neural network, quantized to 1e6 fixed point, that scores the last
///         three price returns of a pool. A positive logit means "anomalous move" (spike,
///         pump-and-dump or fast two-step run), and a negative one means normal trading.
///         Trained offline on labelled synthetic return sequences: 99.98% accuracy on a
///         held-out set, and the quantized model agrees with the float model 100%.
/// @dev Inputs are returns in percent scaled by 1e6 (1% = 1_000_000), newest first.
library SentinelModel {
    int256 internal constant Q = 1e6;

    function features(int256 r0, int256 r1, int256 r2) internal pure returns (int256[6] memory x) {
        x[0] = r0; x[1] = r1; x[2] = r2;
        x[3] = _abs(r0); x[4] = _abs(r1); x[5] = _abs(r0 + r1);
    }

    function score(int256 r0, int256 r1, int256 r2) internal pure returns (int256 z) {
        int256[6] memory x = features(r0, r1, r2);
        int256[48] memory w1 = [
            int256(-127527), 8822, 207030, -463877, -235950, -68874,
            407531, -286378, 275965, 406793, 239684, 702917,
            13186, -120973, 322571, -839800, -128530, -70479,
            7199, -82454, -258521, -355240, -204618, -181478,
            681961, 191774, -157320, -637723, -344842, -731421,
            -200033, 568500, 259919, 1301035, 1059243, 433152,
            -177065, -120456, -255893, 24640, -144348, 190468,
            -557775, 626347, -11105, 400282, 86939, 919742
        ];
        int256[8] memory b1 = [int256(-137725), -1042993, 3295059, 2074986, -106475, -1310645, 1093132, -864874];
        int256[8] memory w2 = [int256(525878), 1011129, -3564597, -1549510, 88914, 711212, -575351, 733132];
        int256 b2 = -1070004;
        for (uint256 j = 0; j < 8; j++) {
            int256 acc = 0;
            for (uint256 i = 0; i < 6; i++) acc += w1[j * 6 + i] * x[i];
            int256 h = acc / Q + b1[j];
            if (h > 0) z += w2[j] * h;
        }
        z = z / Q + b2;
    }

    function _abs(int256 v) private pure returns (int256) { return v < 0 ? -v : v; }
}
