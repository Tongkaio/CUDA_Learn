#include <stdio.h>
#include <stdlib.h>
#include "utils.cuh"

void host_reduce(float* x, const int N, float* sum) {
    *sum = 0.0;
    for (int i = 0; i < N; i++) {
        *sum += x[i];
    }
}

// reduce_v0：使用全局内存
__global__ void device_reduce_v0(float* d_x, float* d_y) {
    const int tid = threadIdx.x;
    float *x = &d_x[blockIdx.x * blockDim.x];  // 当前block所处理元素块的首地址

    for (int offset = blockDim.x >> 1; offset > 0; offset >>= 1) {
        if (tid < offset) {
            x[tid] += x[tid + offset];
        }
        __syncthreads();
    }
    if (tid == 0) {
        d_y[blockIdx.x] = x[0];
    }
}

template <const int BLOCK_SIZE>
void call_reduce_v0(float* d_x, float* d_y, float* h_y, const int N, float* sum) {
    const int GRID_SIZE = CEIL(N, BLOCK_SIZE);
    dim3 block_size(BLOCK_SIZE);
    dim3 grid_size(GRID_SIZE);
    device_reduce_v0<<<grid_size, block_size>>>(d_x, d_y);
    cudaMemcpy(h_y, d_y, sizeof(float) * GRID_SIZE, cudaMemcpyDeviceToHost);
    cudaDeviceSynchronize();
    // 在主机端需要再归约一遍
    *sum = 0.0;
    for (int i = 0; i < GRID_SIZE; i++) {
        *sum += h_y[i];
    }
}

// reduce_v1：使用（静态）共享内存
template <const int BLOCK_SIZE>
__global__ void device_reduce_v1(float* d_x, float* d_y, const int N) {
    const int tid = threadIdx.x;
    const int bid = blockIdx.x;
    const int n = bid * blockDim.x + tid;
    __shared__ float s_y[BLOCK_SIZE];
    s_y[tid] = (n < N) ? d_x[n] : 0.0;  // 搬运global mem 到 shared mem
    __syncthreads();

    for (int offset = blockDim.x >> 1; offset > 0; offset >>= 1) {
        if (tid < offset) {
            s_y[tid] += s_y[tid + offset];
        }
        __syncthreads();
    }
    if (tid == 0) {
        d_y[bid] = s_y[0];
    }
}

template <const int BLOCK_SIZE>
void call_reduce_v1(float* d_x, float* d_y, float* h_y, const int N, float* sum) {
    const int GRID_SIZE = CEIL(N, BLOCK_SIZE);
    dim3 block_size(BLOCK_SIZE);
    dim3 grid_size(GRID_SIZE);
    device_reduce_v1<BLOCK_SIZE><<<grid_size, block_size>>>(d_x, d_y, N);
    cudaMemcpy(h_y, d_y, sizeof(float) * GRID_SIZE, cudaMemcpyDeviceToHost);
    cudaDeviceSynchronize();
    // 在主机端需要再归约一遍
    *sum = 0.0;
    for (int i = 0; i < GRID_SIZE; i++) {
        *sum += h_y[i];
    }
}

// reduce_v2：使用（动态）共享内存
__global__ void device_reduce_v2(float* d_x, float* d_y, const int N) {
    const int tid = threadIdx.x;
    const int bid = blockIdx.x;
    const int n = bid * blockDim.x + tid;
    extern __shared__ float s_y[];  // 动态共享内存
    s_y[tid] = (n < N) ? d_x[n] : 0.0;  // 搬运global mem 到 shared mem
    __syncthreads();

    for (int offset = blockDim.x >> 1; offset > 0; offset >>= 1) {
        if (tid < offset) {
            s_y[tid] += s_y[tid + offset];
        }
        __syncthreads();
    }
    if (tid == 0) {
        d_y[bid] = s_y[0];
    }
}

template <const int BLOCK_SIZE>
void call_reduce_v2(float* d_x, float* d_y, float* h_y, const int N, float* sum) {
    const int GRID_SIZE = CEIL(N, BLOCK_SIZE);
    dim3 block_size(BLOCK_SIZE);
    dim3 grid_size(GRID_SIZE);
    device_reduce_v2<<<grid_size, block_size, sizeof(float) * BLOCK_SIZE>>>(d_x, d_y, N);  // 使用（动态）共享内存
    cudaMemcpy(h_y, d_y, sizeof(float) * GRID_SIZE, cudaMemcpyDeviceToHost);
    cudaDeviceSynchronize();
    // 在主机端需要再归约一遍
    *sum = 0.0;
    for (int i = 0; i < GRID_SIZE; i++) {
        *sum += h_y[i];
    }
}

// reduce_v3：改进，引入原子函数，不需要再到CPU进行归约了
__global__ void device_reduce_v3(float* d_x, float* d_y, const int N) {
    const int tid = threadIdx.x;
    const int bid = blockIdx.x;
    const int n = bid * blockDim.x + tid;
    extern __shared__ float s_y[];  // 动态共享内存
    s_y[tid] = (n < N) ? d_x[n] : 0.0;  // 搬运global mem 到 shared mem
    __syncthreads();

    for (int offset = blockDim.x >> 1; offset > 0; offset >>= 1) {
        if (tid < offset) {
            s_y[tid] += s_y[tid + offset];
        }
        __syncthreads();
    }
    if (tid == 0) {
        atomicAdd(d_y, s_y[0]);  // 原子函数，将取出*d_y，与s_y[0]求和后，再根据地址d_y写回去
        // *d_y += s_y[0];  // 错误，因为d_y如果被多个线程同时读取，再写入时结果就会发生错误
    }
}

template <const int BLOCK_SIZE>
void call_reduce_v3(float* d_x, float* d_y, float* h_y, const int N) {
    const int GRID_SIZE = CEIL(N, BLOCK_SIZE);
    dim3 block_size(BLOCK_SIZE);
    dim3 grid_size(GRID_SIZE);
    *h_y = 0.0;  // host端d_y清零
    cudaMemcpy(d_y, h_y, sizeof(float), cudaMemcpyHostToDevice);  // 拷贝给d_y
    device_reduce_v3<<<grid_size, block_size, sizeof(float) * BLOCK_SIZE>>>(d_x, d_y, N);  // 使用（动态）共享内存
    cudaMemcpy(h_y, d_y, sizeof(float), cudaMemcpyDeviceToHost);  // 拷贝回h_y
    cudaDeviceSynchronize();
}

int main() {
    size_t N = 100000000;
    constexpr size_t BLOCK_SIZE = 128;
    const int repeat_times = 10;

    // 1. host
    float *h_nums = (float *)malloc(sizeof(float) * N);
    float *sum = (float *)malloc(sizeof(float));
    randomize_matrix(h_nums, N);
    
    float total_time_h = TIME_RECORD(repeat_times, ([&]{host_reduce(h_nums, N, sum);}));
    // printf("init_matrix:\n");
    // print_matrix(h_nums, 1, N);
    printf("[reduce_host]: sum = %f, total_time_h = %f ms\n", *sum, total_time_h / repeat_times);

    // 2. device
    float *d_nums, *d_rd_nums;
    cudaMalloc((void **) &d_nums, sizeof(float) * N);
    cudaMalloc((void **) &d_rd_nums, sizeof(float) * CEIL(N, BLOCK_SIZE));
    float *h_rd_nums = (float *)malloc(sizeof(float) * CEIL(N, BLOCK_SIZE));
    
    // 2.1 call reduce_v0, 全局内存，因为reduce会把归约结果累加到d_nums（global memory）上，所以重复执行reduce_v0，得到的sum会越来越大
    cudaMemcpy(d_nums, h_nums, sizeof(float) * N, cudaMemcpyHostToDevice);
    float total_time_0 = TIME_RECORD(repeat_times, ([&]{call_reduce_v0<BLOCK_SIZE>(d_nums, d_rd_nums, h_rd_nums, N, sum);}));
    printf("[reduce_v0]: sum = %f, total_time_0 = %f ms\n", *sum, total_time_0 / repeat_times);

    // 2.2 call reduce_v1，使用静态共享内存，重复执行，sum不受影响
    cudaMemcpy(d_nums, h_nums, sizeof(float) * N, cudaMemcpyHostToDevice);
    float total_time_1 = TIME_RECORD(repeat_times, ([&]{call_reduce_v1<BLOCK_SIZE>(d_nums, d_rd_nums, h_rd_nums, N, sum);}));
    printf("[reduce_v1]: sum = %f, total_time_1 = %f ms\n", *sum, total_time_1 / repeat_times);    

    // 2.3 call reduce_v2，在v1基础上改成动态共享内存，性能维持不变
    cudaMemcpy(d_nums, h_nums, sizeof(float) * N, cudaMemcpyHostToDevice);
    float total_time_2 = TIME_RECORD(repeat_times, ([&]{call_reduce_v2<BLOCK_SIZE>(d_nums, d_rd_nums, h_rd_nums, N, sum);}));
    printf("[reduce_v2]: sum = %f, total_time_2 = %f ms\n", *sum, total_time_2 / repeat_times);

    // 2.4 call reduce_v2，在v2基础上引入原子函数，不需要再到CPU进行归约了
    float *d_sum;
    cudaMalloc((void **) &d_sum, sizeof(float));
    cudaMemcpy(d_nums, h_nums, sizeof(float) * N, cudaMemcpyHostToDevice);
    float total_time_3 = TIME_RECORD(repeat_times, ([&]{call_reduce_v3<BLOCK_SIZE>(d_nums, d_sum, sum, N);}));
    printf("[reduce_v3]: sum = %f, total_time_3 = %f ms\n", *sum, total_time_3 / repeat_times);    

    // free memory
    free(h_nums);
    free(sum);
    free(h_rd_nums);
    cudaFree(d_nums);
    cudaFree(d_rd_nums);
    cudaFree(d_sum);
    return 0;
}