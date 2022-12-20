#include <algorithm>
#include <array>
#include <asio.hpp>
#include <chrono>
#include <iostream>
#include <random>
#include <vector>

using namespace std::chrono;

void quickSort(asio::io_context& ctx, std::vector<int>::iterator begin, std::vector<int>::iterator end) {
    if (std::distance(begin, end) <= 32) {
        // Use std::sort for small inputs
        std::sort(begin, end);
    } else {
        asio::steady_timer timer{ctx};

        auto pivot = begin + std::distance(begin, end) - 1;
        auto i = begin;
        for (auto j = begin; j < pivot; ++j) {
            if (*j <= *pivot) {
                std::swap(*i, *j);
                ++i;
            }
        }
        std::swap(*i, *pivot);
        
        // Create a strand to wrap the async calls to quickSort
        asio::io_context::strand strand{ctx};
        auto quickSortWrapper = [&](auto&& begin, auto&& end) {
            quickSort(ctx, begin, end);
        };
        
        // Use the strand to post the async calls to quickSort
        strand.post(std::bind(quickSortWrapper, begin, i));
        strand.post(std::bind(quickSortWrapper, i + 1, end));
    }
}

void shuffle(std::vector<int>& arr) {
    std::mt19937 rng(std::random_device{}());
    std::shuffle(std::begin(arr), std::end(arr), rng);
}

int main() {
    std::vector<int> arr(10'000'000);

    std::cout << "filling" << std::endl;
    std::iota(std::begin(arr), std::end(arr), 0);

    std::cout << "shuffling" << std::endl;
    shuffle(arr);

    std::cout << "running" << std::endl;
    const int num_threads = std::thread::hardware_concurrency();
    asio::io_context ctx{num_threads};
    const auto start = high_resolution_clock::now();
    quickSort(ctx, std::begin(arr), std::end(arr));
    
    // Run the io_context to process the posted tasks
    ctx.run();
    
    const auto elapsed =
        duration_cast<milliseconds>(high_resolution_clock::now() - start);
    std::cout << "took " << elapsed.count() << "ms" << std::endl;

    if (!is_sorted(std::begin(arr), std::end(arr))) {
        throw std::runtime_error("array not sorted");
    }
}