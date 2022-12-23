#include <algorithm>
#include <asio.hpp>
#include <asio/experimental/parallel_group.hpp>
#include <chrono>
#include <iostream>
#include <random>
#include <vector>

using namespace std::chrono;

template <typename Executor, typename RandomAccessIterator,
          ASIO_COMPLETION_TOKEN_FOR(void()) CompletionToken>
auto parallel_sort(Executor executor, RandomAccessIterator begin,
                   RandomAccessIterator end, CompletionToken &&token);

void quickSort(std::vector<int>::iterator begin,
               std::vector<int>::iterator end);

template <typename Executor, typename RandomAccessIterator>
void parallel_sort_impl(Executor executor, RandomAccessIterator begin,
                        RandomAccessIterator end,
                        std::function<void()> continuation) {
  std::size_t n = end - begin;
  if (n <= 1000) {
    asio::post(executor, [=] {
      quickSort(begin, end);
      continuation();
    });
  } else {
    asio::experimental::make_parallel_group(
        [=](auto token) {
          return parallel_sort(executor, begin, begin + n / 2, token);
        },
        [=](auto token) {
          return parallel_sort(executor, begin + n / 2, end, token);
        })
        .async_wait(asio::experimental::wait_for_all(),
                    [=](std::array<std::size_t, 2>) {
                      std::inplace_merge(begin, begin + n / 2, end);
                      continuation();
                    });
  }
}

template <typename Executor, typename RandomAccessIterator,
          ASIO_COMPLETION_TOKEN_FOR(void()) CompletionToken>
auto parallel_sort(Executor executor, RandomAccessIterator begin,
                   RandomAccessIterator end, CompletionToken &&token) {
  return asio::async_compose<CompletionToken, void()>(
      [=](auto &self, auto... args) {
        if (sizeof...(args) == 0) {
          using self_type = std::decay_t<decltype(self)>;
          parallel_sort_impl(
              executor, begin, end,
              [self = std::make_shared<self_type>(std::move(self))] {
                asio::dispatch(asio::append(std::move(*self), 0));
              });
        } else {
          self.complete();
        }
      },
      token);
}

void quickSort(std::vector<int>::iterator begin,
               std::vector<int>::iterator end) {
  if (std::distance(begin, end) <= 32) {
    // Use std::sort for small inputs
    std::sort(begin, end);
  } else {

    auto pivot = begin + std::distance(begin, end) - 1;
    auto i = std::partition(begin, pivot, [=](int x) { return x <= *pivot; });
    std::swap(*i, *pivot);

    auto quickSortWrapper = [&](auto &&begin, auto &&end) {
      quickSort(begin, end);
    };

    quickSortWrapper(begin, i);
    quickSortWrapper(i + 1, end);
  }
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
  asio::thread_pool pool(num_threads);
  const auto start = high_resolution_clock::now();

  parallel_sort(pool.get_executor(), std::begin(arr), std::end(arr),
                asio::use_future)
      .get();

  const auto elapsed =
      duration_cast<milliseconds>(high_resolution_clock::now() - start);
  std::cout << "took " << elapsed.count() << "ms" << std::endl;

  if (!is_sorted(std::begin(arr), std::end(arr))) {
    throw std::runtime_error("array not sorted");
  }
}