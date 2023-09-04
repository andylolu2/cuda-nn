#pragma once
#include <cutlass/arch/arch.h>
#include <cutlass/epilogue/thread/linear_combination.h>
#include <cutlass/numeric_types.h>

#include <cuda/std/type_traits>
#include <cute/algorithm/gemm.hpp>
#include <cute/atom/copy_atom.hpp>
#include <cute/tensor.hpp>
#include <cutlass/epilogue/collective/default_epilogue.hpp>
#include <cutlass/gemm/collective/collective_mma.hpp>
#include <cutlass/gemm/dispatch_policy.hpp>

#include "lib/functions.cuh"

using namespace cute;

namespace lib {
    template <
        typename PrologueOp,
        typename EpilogueOp,
        typename EngineA,
        typename LayoutA,
        typename ABlockLayout,
        typename AThreadLayout,
        typename EngineB,
        typename LayoutB,
        typename BBlockLayout,
        typename BThreadLayout,
        typename EngineC,
        typename LayoutC,
        typename CBlockLayout,
        typename CThreadLayout,
        typename EngineD,
        typename LayoutD>
    __device__ void gemm_device(
        Tensor<EngineA, LayoutA> &mA,
        Tensor<EngineB, LayoutB> &mB,
        Tensor<EngineC, LayoutC> &mC,
        Tensor<EngineD, LayoutD> &tCrC,  // Output
        ABlockLayout &blockA,
        AThreadLayout &tA,
        BBlockLayout &blockB,
        BThreadLayout &tB,
        CBlockLayout &blockC,
        CThreadLayout &tC) {
        using X = Underscore;
        using TA = typename EngineA::value_type;
        using TB = typename EngineB::value_type;

        // Preconditions
        CUTE_STATIC_ASSERT(is_static<ABlockLayout>::value);
        CUTE_STATIC_ASSERT(is_static<BBlockLayout>::value);
        CUTE_STATIC_ASSERT(is_static<CBlockLayout>::value);

        CUTE_STATIC_ASSERT(is_static<AThreadLayout>::value);
        CUTE_STATIC_ASSERT(is_static<BThreadLayout>::value);
        CUTE_STATIC_ASSERT(is_static<CThreadLayout>::value);

        // Each thread should handle exactly two copy operations and one compute operation
        CUTE_STATIC_ASSERT_V(size(tA) == size(tC));
        CUTE_STATIC_ASSERT_V(size(tB) == size(tC));

        CUTE_STATIC_ASSERT_V(shape<0>(blockA) == shape<0>(blockC));  // BLK_M
        CUTE_STATIC_ASSERT_V(shape<0>(blockB) == shape<1>(blockC));  // BLK_N
        CUTE_STATIC_ASSERT_V(shape<1>(blockA) == shape<1>(blockB));  // BLK_K

        // --- Global ---
        auto M = size<0>(mA.shape());
        auto N = size<0>(mB.shape());
        auto K = size<1>(mA.shape());

        // --- Thread block level ---
        //  1. copy gA (global memory) -> sA (shared memory)
        //  2. copy gB (global memory) -> sB (shared memory)
        //  3. compute gC += sA @ sB
        // where gA & sA are fragments of mA, gB & sB are fragments of mB, gC is a fragment of mC.

        // Block size of the compute tile
        auto BLK_M = shape<0>(blockC);
        auto BLK_N = shape<1>(blockC);
        auto BLK_K = shape<1>(blockA);

        // Compute the "residues"
        auto m_residue = min(BLK_M, M - blockIdx.x * BLK_M);
        auto n_residue = min(BLK_N, N - blockIdx.y * BLK_N);

        __shared__ TA smemA[cosize_v<ABlockLayout>];
        __shared__ TB smemB[cosize_v<BBlockLayout>];
        auto sA = make_tensor(make_smem_ptr(smemA), blockA);  // (BLK_M BLK_K)
        auto sB = make_tensor(make_smem_ptr(smemB), blockB);  // (BLK_N BLK_K)

        auto blk_shape = make_shape(BLK_M, BLK_N, BLK_K);
        auto blk_coord = make_coord(blockIdx.x, blockIdx.y, _);  // (m n k)

        // k := K / BLK_K, the number of blocks in the K-dimension
        auto gA = local_tile(mA, blk_shape, blk_coord, Step<_1, X, _1>{});  // (BLK_M BLK_K k)
        auto gB = local_tile(mB, blk_shape, blk_coord, Step<X, _1, _1>{});  // (BLK_N BLK_K k)
        auto gC = local_tile(mC, blk_shape, blk_coord, Step<_1, _1, X>{});  // (BLK_M BLK_N)

        auto tCgC = local_partition(gC, tC, threadIdx.x, Step<_1, _1>{});

        // --- Thread level ---
        // for k_blk_idx in range(k):
        //   1. copy tAgA[:, :, k_blk_idx] (global memory) -> tAsA (shared memory)
        //   2. copy tBgB[:, :, k_blk_idx] (global memory) -> tBsB (shared memory)
        //   3. compute tCrC += tCsA @ tCsB
        //  where
        //   - tAgA is a fragment of gA
        //   - tBgB is a fragment of gB
        //   - tAsA is a fragment of sA (view used for copy)
        //   - tCsA is a fragment of sA (view used for compute)
        //   - tBsB is a fragment of sB (view used for copy)
        //   - tCsB is a fragment of sB (view used for compute)
        //   - tCrC is a fragment of gC (stored in register memory)

        // gA (BLK_M BLK_K k) / tA -> tAgA (BLK_M/tA.M BLK_K/tA.K k)
        auto tAgA = local_partition(gA, tA, threadIdx.x);
        // sA (BLK_M BLK_K) / tA -> tAsA (BLK_M/tA.M BLK_K/tA.K)
        auto tAsA = local_partition(sA, tA, threadIdx.x);
        // predicate mask for the tAgA -> tAsA copy (BLK_M/tA.M BLK_K/tA.K)
        auto tApA = make_tensor<bool>(make_shape(size<0>(tAgA), size<1>(tAgA)));

        // gB (BLK_N BLK_K k) / tB -> tBgB (BLK_N/tB.N BLK_K/tB.K k)
        auto tBgB = local_partition(gB, tB, threadIdx.x);
        // sB (BLK_N BLK_K) / tB -> tBsB (BLK_N/tB.N BLK_K/tB.K)
        auto tBsB = local_partition(sB, tB, threadIdx.x);
        // predicate mask for the tBgB -> tBsB copy (BLK_N/tB.N BLK_K/tB.K)
        auto tBpB = make_tensor<bool>(make_shape(size<0>(tBgB), size<1>(tBgB)));

        // sA (BLK_M BLK_K) by the rows of tC (tC.M tC.N) -> (BLK_M/tC.M BLK_K)
        auto tCsA = local_partition(sA, tC, threadIdx.x, Step<_1, X>{});
        // sB (BLK_N BLK_K) by the cols of tC (tC.M tC.N) -> (BLK_N/tC.N BLK_K)
        auto tCsB = local_partition(sB, tC, threadIdx.x, Step<X, _1>{});

        // (BLK_M,BLK_K) -> (blk_m,blk_k)
        Tensor cA = make_identity_tensor(make_shape(size<0>(sA), size<1>(sA)));
        Tensor tAcA = local_partition(cA, tA, threadIdx.x);
        // (BLK_N,BLK_K) -> (blk_n,blk_k)
        Tensor cB = make_identity_tensor(make_shape(size<0>(sB), size<1>(sB)));
        Tensor tBcB = local_partition(cB, tB, threadIdx.x);

        // Clear the accumulators
        clear(tCrC);

        auto k = size<2>(tAgA);
        for (int k_blk_idx = 0; k_blk_idx < k; ++k_blk_idx) {
            // Step 1 & 2
            auto k_residue = K - k_blk_idx * BLK_K;
            clear(tAsA);
            clear(tBsB);

            // Populate the predicate masks
            CUTE_UNROLL
            for (int m = 0; m < size<0>(tApA); ++m) {
                CUTE_UNROLL
                for (int k_idx = 0; k_idx < BLK_K; ++k_idx) {
                    tApA(m, k_idx) = elem_less(tAcA(m, k_idx), make_coord(m_residue, k_residue));
                }
            }
            CUTE_UNROLL
            for (int n = 0; n < size<0>(tBpB); ++n) {
                CUTE_UNROLL
                for (int k_idx = 0; k_idx < BLK_K; ++k_idx) {
                    tBpB(n, k_idx) = elem_less(tBcB(n, k_idx), make_coord(n_residue, k_residue));
                }
            }
            copy_if(tApA, tAgA(_, _, k_blk_idx), tAsA);
            copy_if(tBpB, tBgB(_, _, k_blk_idx), tBsB);

            CUTE_UNROLL
            for (int i = 0; i < size(tAsA); ++i) {
                tAsA(i) = PrologueOp{}(tAsA(i));
            }

            cp_async_fence();
            cp_async_wait<0>();

            __syncthreads();

            // Step 3
            gemm(tCsA, tCsB, tCrC);

            __syncthreads();
        }

        CUTE_UNROLL
        for (int i = 0; i < size(tCrC); ++i) {
            auto x = tCrC(i) + tCgC(i);  // A @ B + C
            tCrC(i) = EpilogueOp{}(x);   // Epilogue(A @ B + C)
        }
    }

    // template <
    //     typename ElementA,
    //     typename StrideA,
    //     typename ElementB,
    //     typename StrideB,
    //     typename ElementC,
    //     typename StrideC,
    //     typename ElementD,
    //     typename StrideD>
    // void gemm(ElementA *A, StrideA stride_A, ElementB *B, StrideB stride_B, ElementC *C) {
    //     using DispatchPolicy = cutlass::gemm::MainloopSm70TwoStage;
    //     using TileShape = cutlass::gemm::GemmShape<128, 128, 8>;  // (BLK_M BLK_N BLK_K)
    //     using TiledMma = TiledMMA<MMA_Atom<UniversalFMA<ElementD, ElementA, ElementB,
    //     ElementC>>>; using GmemTiledCopyA = SM75_U32x1_LDSM_N; using SmemLayoutAtomA = Layout<32,
    //     8>;  // (tA.M tA.K) using SmemCopyAtomA = Copy_Atom<SM75_U32x1_LDSM_N, ElementA>; using
    //     TransformA = cute::identity; using GmemTiledCopyB = SM75_U32x1_LDSM_N; using
    //     SmemLayoutAtomB = Layout<32, 8>;  // (tB.N tB.K) using SmemCopyAtomB =
    //     Copy_Atom<SM75_U32x1_LDSM_N, ElementB>; using TransformB = cute::identity;

    //     // Step 1: Generate the required collective layer mainloop specialization
    //     using CollectiveMainloop = typename cutlass::gemm::collective::CollectiveMma<
    //         DispatchPolicy,
    //         TileShape,
    //         ElementA,
    //         StrideA,
    //         ElementB,
    //         StrideB,
    //         TiledMma,
    //         GmemTiledCopyA,
    //         SmemLayoutAtomA,
    //         SmemCopyAtomA,
    //         TransformA,
    //         GmemTiledCopyB,
    //         SmemLayoutAtomB,
    //         SmemCopyAtomB,
    //         TransformB>;

    //     // Step 2: Specify the collective layer epilogue type
    //     using CollectiveEpilogue = cutlass::epilogue::collective::DefaultEpilogue<
    //         StrideC,
    //         StrideD,
    //         epilogue::thread::LinearCombination<
    //             ElementC,
    //             128 / cutlass::sizeof_bits(ElementD)::value,
    //             ElementD,
    //             ElementC>,
    //         cutlass::gemm::EpilogueDefault>;

    //     // Step 3: Compose the mainloop and epilogue together at the kernel layer
    //     using GemmKernel = cutlass::gemm::kernel::GemmUniversal<
    //         cute::Shape<int, int, int, int>,  // ProblemShape [M,N,K,L]
    //         CollectiveMainloop,
    //         CollectiveEpilogue>;

    //     // Step 4: Wrap up the kernel::GemmUniversal kernel class
    //     // with the device adapter to obtain a host-side handle to the kernel
    //     using Gemm = cutlass::gemm::device::GemmUniversalAdapter<GemmKernel>;

    //     // Step 5: Instantiate the GemmHandle
    //     Gemm gemm_op;
    // }
}  // namespace lib
