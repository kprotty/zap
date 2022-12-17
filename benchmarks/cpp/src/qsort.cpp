#include <algorithm>
#include <array>
#include <asio.hpp>
#include <chrono>
#include <iostream>
#include <random>
#include <vector>

using namespace std::chrono;

void insertionSort(std::vector<int>& arr);
int partition(std::vector<int>& arr);

void shuffle(std::vector<int>& arr) {
    std::mt19937 rng(std::random_device{}());
    std::shuffle(std::begin(arr), std::end(arr), rng);
}

void quickSort(std::vector<int>& arr) {
    if (arr.size() <= 32) {
        insertionSort(arr);
    } else {
        asio::io_context ctx;
        asio::steady_timer timer{ctx};

        std::vector<int> arr1, arr2;
        const auto pivot = partition(arr);
        arr1.assign(std::begin(arr), begin(arr) + pivot);
        arr2.assign(std::begin(arr) + pivot, end(arr));
        
        std::async(std::launch::async, [&] { quickSort(arr1); });
        std::async(std::launch::async, [&] { quickSort(arr2); });
        ctx.run();
        
        std::copy(begin(arr1), end(arr1), begin(arr));
        std::copy(begin(arr2), end(arr2), begin(arr) + pivot);
    }
}

int partition(std::vector<int>& arr) {
    const auto pivot = arr.size() - 1;
    int i = 0;
    for (unsigned long j = 0; j < pivot; ++j) {
        if (arr[j] <= arr[pivot]) {
            std::swap(arr[i], arr[j]);
            ++i;
        }
    }
    std::swap(arr[i], arr[pivot]);
    return i;
}

void insertionSort(std::vector<int>& arr) {
    for (int i = 1; i < arr.size(); ++i) {
        for (unsigned long n = i; n > 0 && arr[n] < arr[n - 1]; --n) {
            std::swap(arr[n], arr[n - 1]);
        }
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
    quickSort(arr);
    const auto elapsed =
        duration_cast<milliseconds>(high_resolution_clock::now() - start);
    std::cout << "took " << elapsed.count() << "ms" << std::endl;

    if (!is_sorted(std::begin(arr), std::end(arr))) {
        throw std::runtime_error("array not sorted");
    }
}
