#include <algorithm>
#include <array>
#include <asio.hpp>
#include <chrono>
#include <iostream>
#include <random>
#include <vector>

using namespace std::chrono;

int partition(std::vector<int>& arr, unsigned long& start, unsigned long& end) {
    const auto pivot = static_cast<unsigned long>(end - 1);
    int i = start;
    for (int j = start; j < pivot; ++j) {
        if (arr[j] <= arr[pivot]) {
            std::swap(arr[i], arr[j]);
            ++i;
        }
    }
    std::swap(arr[i], arr[pivot]);
    return i;
}

void insertionSort(std::vector<int>& arr, unsigned long& start, unsigned long& end) {
    for (int i = start + 1; i < end; ++i) {
        for (unsigned long n = i; n > start && arr[n] < arr[n - 1]; --n) {
            std::swap(arr[n], arr[n - 1]);
        }
    }
}

void shuffle(std::vector<int>& arr) {
    std::mt19937 rng(std::random_device{}());
    std::shuffle(std::begin(arr), std::end(arr), rng);
}

void quickSort(std::vector<int>& arr, unsigned long& start, unsigned long& end) {
    if (end - start <= 32) {
        insertionSort(arr, start, end);
    } else {
        asio::io_context ctx;
        asio::steady_timer timer{ctx};

        const auto pivot = partition(arr, start, end);
        
        // Create a strand to wrap the async calls to quickSort
        asio::io_context::strand strand{ctx};
        auto quickSortWrapper = [&](auto&& arr, auto start, auto end) {
            quickSort(arr, start, end);
        };
        
        // Use the strand to dispatch the async calls to quickSort
        strand.dispatch(std::bind(quickSortWrapper, std::ref(arr), start, start + pivot));
        strand.dispatch(std::bind(quickSortWrapper, std::ref(arr), start + pivot, end));
        
        std::cout << start << " - " << end << "\n";
        // Run the io_context to process the dispatched tasks
        ctx.run();
    }
}

int main() {
    std::vector<int> arr(10'000'000);

    std::cout << "filling" << std::endl;
    std::iota(std::begin(arr), std::end(arr), 0);

    std::cout << "shuffling" << std::endl;
    shuffle(arr);

    std::cout << "running" << std::endl;
    const auto start = high_resolution_clock::now();
    unsigned long begin = 0;
    unsigned long end = arr.size();
    quickSort(arr, begin, end);
    const auto elapsed =
        duration_cast<milliseconds>(high_resolution_clock::now() - start);
    std::cout << "took " << elapsed.count() << "ms" << std::endl;

    if (!is_sorted(std::begin(arr), std::end(arr))) {
        throw std::runtime_error("array not sorted");
    }
}
