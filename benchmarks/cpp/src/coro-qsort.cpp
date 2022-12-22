#include <algorithm>
#include <array>
#include <asio.hpp>
#include <chrono>
#include <iostream>
#include <random>
#include <vector>

using namespace std::chrono;
using asio::awaitable;
using asio::co_spawn;
using asio::detached;

awaitable<void> quickSort(asio::io_context &ctx,
                          std::vector<int>::iterator begin,
                          std::vector<int>::iterator end) {
  if (std::distance(begin, end) <= 32) {
    // Use std::sort for small inputs
    std::sort(begin, end);
  } else {
    auto pivot = begin + std::distance(begin, end) - 1;
    auto i = std::partition(begin, pivot, [=](int x) { return x <= *pivot; });
    std::swap(*i, *pivot);

    co_await quickSort(ctx, begin, i);
    co_await quickSort(ctx, i + 1, end);
  }
  co_return;
}

void shuffle(std::vector<int> &arr) {
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

  co_spawn(
      ctx,
      [&]() -> awaitable<void> {
        co_await quickSort(ctx, std::begin(arr), std::end(arr));
      },
      detached);

  // Run the io_context to process the posted tasks
  ctx.run();

  const auto elapsed =
      duration_cast<milliseconds>(high_resolution_clock::now() - start);
  std::cout << "took " << elapsed.count() << "ms" << std::endl;

  if (!is_sorted(std::begin(arr), std::end(arr))) {
    throw std::runtime_error("array not sorted");
  }
}