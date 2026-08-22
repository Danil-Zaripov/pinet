# Performance and Memory Efficiency Benchmark Report: BasicHeap vs. ObjPool Allocators

## 1. Evaluation Context & Environment

The benchmarking experiments were conducted on a dedicated workstation under controlled environment variables to minimize noise and ensure high reproducibility.

* **Hardware Configuration:**
* **Processor (CPU):** AMD Ryzen 7 8845HS
* **RAM:** 32 GB (4 x 8 GB) LPDDR5 @ 6400 MT/s


* **Software Configuration:**
* **Operating System:** Fedora Linux 44 (Workstation Edition)
* **Kernel Version:** 7.0.11-200.fc44.x86_64


* **Compiler Settings:**
* **Compiler Version:** Zig 0.16.0
* **Build Mode / Optimization Level:** `-Doptimize=ReleaseFast` (Agressive optimizations enabled, safety checks disabled for maximum execution paths speed)


---

## 2. Benchmarking Methodology

To achieve statistically sound metrics, the evaluation adhered to the following rigorous workflow:

1. **Sample Size and Iterations:** For each given buffer size configuration (the `-m` flag), the application was executed for 7 independent runs. A comprehensive matrix of 17 buffer sizes across 7 iterations (119 runs in total per allocator) was evaluated. The visualization data points represent the mathematical mean of these runs.
2. **Instrumentation and Profiling:** * **Execution Time:** Measured using three high-resolution hardware/software timers embedded directly into the virtual machine (`pinet`).
* **Low-Level Analysis:** CPU cycle sampling and call chain tracking were conducted utilizing the Linux `perf` utility. Samples were acquired with call-graph recording (`-g graph`) to precisely reconstruct full execution stacks and account for heavily inlined compiler functions.


3. **Workload Profile:** The test utilizes a merge sort algorithm (`merge_sort.in`), representing a highly demanding allocation-heavy scenario with rapid alternating cycles of object creation and destruction. The peak heap utilization baseline was established at `-m 1199953`.

---

## 3. Architectural Design of the Investigated Allocators

* **BasicHeap (Baseline Allocator):** Employs a linear lookup mechanism over free slots wrapped inside a `union(enum)` structure. This introduces an allocation time complexity of $O(N)$ in the worst-case scenario.
* **ObjPool (Optimized Allocator):** Implements a fixed-size object pool leveraging an *Embedded Free-List* and strict pointer alignment constraints. This design guarantees a constant time complexity of $O(1)$ for both allocation and deallocation operations.

---

## 4. Spatial Metrics & Memory Efficiency Analysis

The architectural shift from `BasicHeap` to `ObjPool` yields substantial improvements in memory overhead.

* **Metadata Overhead Reduction:** `BasicHeap` incurs heavy tracking penalties due to its structural layout wrapper. For agent-type allocations, the lower-bound estimate of the memory overhead reaches **32% to 33.3%** (8 bytes of metadata overhead for every 24 bytes of actual agent payload).
* **ObjPool Efficiency:** By embedding the free-list pointers directly into the unallocated memory slots themselves, `ObjPool` drops the fixed-size element tracking overhead down to **0 bytes** during active pool state. In large-scale, memory-intensive programs, the 32% overhead from the old allocator severely degrades memory footprints and can lead to early out-of-memory states under heavy scaling.


![Memory Overhead Comparison](images/MemoryUsage.png)

---

## 5. Temporal Metrics & Performance Evaluation

The execution of the `pinet` VM tracks three discrete phases: Preparation Time (parsing/compilation), Core Execution Time (the runtime of the sorting algorithm involving agent management), and Cleanup/Deallocation Time.

The primary metric evaluated is the **Core Execution Time (Second Timer)**, capturing the true runtime performance of the allocators under load.

### Comparative Performance Dataset

The table below summarizes the core execution times across 12 key test points:

| Memory Buffer Size (`-m`) | ObjPool Time (sec) | BasicHeap Time (sec) | Speedup Factor |
| --- | --- | --- | --- |
| 1,199,953 (Peak Load Baseline) | 4.8629 | 5.9333 | 1.22x |
| 1,200,000 | 5.3450 | 5.9421 | 1.11x |
| 1,300,000 | 5.1409 | 5.9936 | 1.17x |
| 1,400,000 | 5.2237 | 5.7713 | 1.10x |
| 1,500,000 | 5.1987 | 5.6007 | 1.08x |
| 16,000,000 * | 5.2130 | 5.5730 | 1.07x |
| 1,800,000 | 5.1070 | 5.3999 | 1.06x |
| 2,000,000 | 4.4839 | 5.2245 | 1.17x |
| 2,100,000 | 4.6093 | 5.1001 | 1.11x |
| 2,200,000 | 4.6619 | 5.0956 | 1.09x |
| 2,300,000 | 4.7877 | 5.5140 | 1.15x |
| 2,400,000 | 5.2273 | 5.1117 | 0.98x |

### Summary Metrics (Averages Across All 12 Data Points)

* **Mean Execution Time (ObjPool):** 4.9884 seconds
* **Mean Execution Time (BasicHeap):** 5.5216 seconds
* **Average Performance Gain:** `ObjPool` operates **1.107x faster** than `BasicHeap`, achieving a net speedup of **10.7%**.
* **Peak Load Performance Gain:** At the strict critical peak threshold (`-m 1199953`), the runtime optimization reaches its maximum efficacy, demonstrating a **22% speedup** (1.22x).

To fully analyze how the system scales across different allocations profiles, refer to the temporal graphs below:


![Average Total Runtime vs. Pool Size](images/main.png)


![Average Core Execution Time (Agent Allocation & Destruction Phase) vs. Pool Size](images/without_init_and_deinit_times.png)


## 6. Low-Level CPU Profiling & Bottleneck Analysis

While changing the algorithmic complexity from $O(N)$ to $O(1)$ successfully eliminated searching overhead and enhanced raw execution speeds, low-level sampling via `perf` reveals why the application does not experience a larger exponential acceleration.

* **CPU Cycle Saturation:** Low-level `perf` reports demonstrate that the application is strictly **memory-bound**.
* **The Allocator Bottleneck:** The core allocator function `allocOne` consumes a staggering **93.63%** of the entire processor runtime. In contrast, the actual computational sorting logic (`merge` and `mergeSort`) accounts for slightly above 4% of total CPU cycles combined.

This massive asymmetry means that any improvements made to the algorithmic search paths are heavily compressed by the sheer overhead of interfacing, type erasure wrapper lookups, and pointer virtualization layers inside the VM environment.


![Allocator Functions CPU Overhead allocOne via perf Report](images/alloc.png)
![Allocator Functions CPU Overhead freeOne via perf Report](images/free.png) 

---

## 7. Conclusion

The implementation of the `ObjPool` allocator with an Embedded Free-List successfully achieved its primary objective: reducing spatial overhead tracking to 0 bytes for fixed-size elements and elevating the algorithmic execution efficiency. The transition yielded an average 10.7% general speedup and a 22% performance increase under peak workload saturation. However, the `perf` analysis isolates the virtual machine's constant internal abstraction layers and allocator function calls as the primary system bottleneck (93.63% CPU overhead), suggesting that future optimizations should focus on function inlining strategies and minimizing abstraction layer friction rather than core pool search logic.
