#include <asio.hpp>
#include <iostream>
#include <vector>
#include <algorithm>
#include <numeric>
#include <random>

using namespace asio;

// A function to perform quicksort on a vector of integers
void quicksort(std::vector<int>& vec, int low, int high)
{
    if (low < high)
    {
        int pivot = low;
        int left = low + 1;
        int right = high;
        while (left <= right)
        {
            while (left <= right && vec[left] <= vec[pivot])
            {
                left++;
            }
            while (left <= right && vec[right] > vec[pivot])
            {
                right--;
            }
            if (left < right)
            {
                std::swap(vec[left], vec[right]);
            }
        }
        std::swap(vec[pivot], vec[right]);
        int pivot_point = right;
        quicksort(vec, low, pivot_point - 1);
        quicksort(vec, pivot_point + 1, high);
    }
}

int main()
{
    io_context io;
    // Create a thread pool with max threads
    unsigned int num_cpus = std::thread::hardware_concurrency();
    io_context::work work{io};
    std::vector<std::thread> threads;
    for (int i = 0; i < num_cpus ; i++)
    {
        threads.emplace_back([&io]{io.run();});
    }

    std::vector<int> vec(10'000'000);
    std::iota(vec.begin(), vec.end(), 10);
    std::shuffle(vec.begin(), vec.end(), std::mt19937{std::random_device{}()});
    // Use a strand to ensure that the quicksort function is executed in order
    // and that no two quicksort tasks are executed concurrently
    io_context::strand strand{io};

    // Start the quicksort task asynchronously
    strand.post([&]{
        quicksort(vec, 0, vec.size() - 1);
    });

    // Wait for the quicksort task to complete
    strand.post([&]{
        // Print the sorted vector
        for (int x : vec)
        {
            std::cout << x << " ";
        }
        std::cout << std::endl;
        // Stop the io_context and all the threads in the thread pool
        io.stop();
    });

    // Wait for all the threads in the thread pool to complete
    for (auto& t : threads)
    {
        t.join();
    }

    return 0;
}

