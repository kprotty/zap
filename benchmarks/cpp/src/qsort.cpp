#include <algorithm>
#include <array>
#include <asio.hpp>
#include <chrono>
#include <iostream>
#include <random>
#include <vector>

using namespace asio;
using namespace std;
using namespace std::chrono;

void insertionSort(vector<int>& arr);
int partition(vector<int>& arr);

void shuffle(vector<int>& arr) {
    mt19937 rng(random_device{}());
    shuffle(begin(arr), end(arr), rng);
}

void quickSort(vector<int>& arr) {
    if (arr.size() <= 32) {
        insertionSort(arr);
    } else {
        io_context ctx;
        steady_timer timer{ctx};
        vector<int> arr1, arr2;
        const auto pivot = partition(arr);
        arr1.assign(begin(arr), begin(arr) + pivot);
        arr2.assign(begin(arr) + pivot, end(arr));
        async(launch::async, [&] { quickSort(arr1); });
        async(launch::async, [&] { quickSort(arr2); });
        ctx.run();
        copy(begin(arr1), end(arr1), begin(arr));
        copy(begin(arr2), end(arr2), begin(arr) + pivot);
    }
}

int partition(vector<int>& arr) {
    const auto pivot = arr.size() - 1;
    int i = 0;
    for (int j = 0; j < pivot; ++j) {
        if (arr[j] <= arr[pivot]) {
            swap(arr[i], arr[j]);
            ++i;
        }
    }
    swap(arr[i], arr[pivot]);
    return i;
}

void insertionSort(vector<int>& arr) {
    for (int i = 1; i < arr.size(); ++i) {
        for (int n = i; n > 0 && arr[n] < arr[n - 1]; --n) {
            swap(arr[n], arr[n - 1]);
        }
    }
}

int main() {
    vector<int> arr(10'000'000);

    cout << "filling" << endl;
    iota(begin(arr), end(arr), 0);

    cout << "shuffling" << endl;
    shuffle(arr);

    cout << "running" << endl;
    const auto start = high_resolution_clock::now();
    quickSort(arr);
    const auto elapsed =
        duration_cast<milliseconds>(high_resolution_clock::now() - start);
    cout << "took " << elapsed.count() << "ms" << endl;

    if (!is_sorted(begin(arr), end(arr))) {
        throw runtime_error("array not sorted");
    }
}
