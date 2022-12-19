#include <algorithm>
#include <asio.hpp>
#include <vector>
#include <iostream>
#include <random>

using namespace std::chrono;
using asio::awaitable;
using asio::co_spawn;
using asio::detached;

constexpr int partition(std::vector<int>& arr, unsigned long start, unsigned long end) noexcept {
    const auto pivot = static_cast<unsigned long>(end - 1);
    int i = start;
    for (unsigned long j = start; j < pivot; ++j) {
        if (arr[j] <= arr[pivot]) {
            std::iter_swap(arr.begin() + i, arr.begin() + j);
            ++i;
        }
    }
    std::iter_swap(arr.begin() + i, arr.begin() + pivot);
    return i;
}

constexpr void insertionSort(std::vector<int>& arr, unsigned long start, unsigned long end) noexcept {
    for (unsigned long i = start + 1; i < end; ++i) {
        for (unsigned long n = i; n > start && arr[n] < arr[n - 1]; --n) {
            std::iter_swap(arr.begin() + n, arr.begin() + n - 1);
        }
    }
}

void shuffle(std::vector<int>& arr) {
    std::mt19937 rng(std::random_device{}());
    std::shuffle(arr.begin(), arr.end(), rng);
}

awaitable<void> quickSort(asio::io_context& ctx, std::vector<int>& arr, unsigned long start, unsigned long end) noexcept {
     std::cout << "Values before co_await: " << start << " - " << end << "\n";
    if (end - start <= end) {
        // slow
        // insertionSort(arr, start, end);
        // fast
        std::sort(arr.begin() + start, arr.begin() + end);
        co_return;
    }

    const auto pivot = partition(arr, start, end);
    co_await quickSort(ctx, arr, start, start + pivot);
    co_await quickSort(ctx, arr, start + pivot, end);
    std::cout << "Values after co_await: " << start << " - " << end << "\n";
}

int main() {
    std::vector<int> arr(10'000'000);

    std::cout << "filling" << std::endl;
    std::iota(arr.begin(), arr.end(), 0);

    std::cout << "shuffling" << std::endl;
    shuffle(arr);

    std::cout << "running" << std::endl;
    const auto start = high_resolution_clock::now();
    asio::io_context ctx{5};

    co_spawn(ctx, [&]() -> awaitable<void> {
        co_await quickSort(ctx, arr, 0, arr.size());
    }, detached);
    ctx.run();

    const auto elapsed =
        duration_cast<milliseconds>(high_resolution_clock::now() - start);
    std::cout << "took " << elapsed.count() << "ms" << std::endl;

    if (!is_sorted(std::begin(arr), std::end(arr))) {
        throw std::runtime_error("array not sorted");
    }
}