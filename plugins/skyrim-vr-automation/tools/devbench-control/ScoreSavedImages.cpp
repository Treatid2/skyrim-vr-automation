// SPDX-License-Identifier: GPL-3.0-or-later
// Link with DevBench's existing Ssim.cpp; keep its decoder and scoring unchanged.
#include "Ssim.h"
#include <fstream>
#include <iostream>
#include <stdexcept>

int main(int argc, char** argv)
{
    try {
        if (argc != 2) throw std::runtime_error("Expected scoring-request JSON path");
        std::ifstream input(argv[1]);
        const auto requests = dvb::json::parse(input);
        auto results = dvb::json::array();
        for (const auto& request : requests) {
            const auto score = dvb::Ssim::ScoreAgainstGolden(
                request.at("candidate").get<std::string>(),
                request.at("golden").get<std::string>(), request.at("config"));
            if (!score.ok) throw std::runtime_error(score.error);
            auto regions = dvb::json::array();
            for (const auto& region : score.regions)
                regions.push_back({ { "name", region.name }, { "ssim", region.score },
                    { "threshold", region.threshold }, { "passed", region.passed } });
            results.push_back({ { "view", request.at("view") }, { "regions", regions },
                { "ssim", score.score }, { "passed", score.passed } });
        }
        std::cout << results.dump(2) << '\n';
        return 0;
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
