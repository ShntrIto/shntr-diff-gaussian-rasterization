#include "rasterizer_impl.h"
#include <iostream>
#include <fstream>
#include <algorithm>
#include <numeric>
#include <cuda.h>
#include "cuda_runtime.h"
#include "device_launch_parameters.h"
#include <cub/cub.cuh>
#include <cub/device/device_radix_sort.cuh>
#include <thrust/sequence.h>
#define GLM_FORCE_CUDA
#include <glm/glm.hpp>

#include <cooperative_groups.h>
#include <cooperative_groups/reduce.h>
namespace cg = cooperative_groups;

#include "auxiliary.h"
#include "forward.h"
#include "backward.h"

// Helper function to find the next-highest bit of the MSB
// on the CPU.
uint32_t getHigherMsb(uint32_t n)
{
	uint32_t msb = sizeof(n) * 4;
	uint32_t step = msb;
	while (step > 1)
	{
		step /= 2;
		if (n >> msb)
			msb += step;
		else
			msb -= step;
	}
	if (n >> msb)
		msb++;
	return msb;
}

// Wrapper method to call auxiliary coarse frustum containment test.
// Mark all Gaussians that pass it.
__global__ void checkFrustum(int P,
	const float* orig_points,
	const float* viewmatrix,
	const float* projmatrix,
	bool* present)
{
	auto idx = cg::this_grid().thread_rank();
	if (idx >= P)
		return;

	float3 p_view;
	present[idx] = in_frustum(idx, orig_points, viewmatrix, projmatrix, false, p_view);
}

// Generates one key/value pair for all Gaussian / tile overlaps. 
// Run once per Gaussian (1:N mapping).
__global__ void duplicateWithKeys(
	int P,
	const float2* points_xy,
	const float* depths,
	const uint32_t* offsets,
	uint64_t* gaussian_keys_unsorted,
	uint32_t* gaussian_values_unsorted,
	int* radii,
	dim3 grid)
{
	auto idx = cg::this_grid().thread_rank();
	if (idx >= P)
		return;

	// Generate no key/value pair for invisible Gaussians
	if (radii[idx] > 0)
	{
		// Find this Gaussian's offset in buffer for writing keys/values.
		uint32_t off = (idx == 0) ? 0 : offsets[idx - 1];
		uint2 rect_min, rect_max;

		getRect(points_xy[idx], radii[idx], rect_min, rect_max, grid);

		// For each tile that the bounding rect overlaps, emit a 
		// key/value pair. The key is |  tile ID  |      depth      |,
		// and the value is the ID of the Gaussian. Sorting the values 
		// with this key yields Gaussian IDs in a list, such that they
		// are first sorted by tile and then by depth. 
		for (int y = rect_min.y; y < rect_max.y; y++)
		{
			for (int x = rect_min.x; x < rect_max.x; x++)
			{
				uint64_t key = y * grid.x + x;
				key <<= 32;
				key |= *((uint32_t*)&depths[idx]);
				gaussian_keys_unsorted[off] = key;
				gaussian_values_unsorted[off] = idx;
				off++;
			}
		}
	}
}

// Check keys to see if it is at the start/end of one tile's range in 
// the full sorted list. If yes, write start/end of this tile. 
// Run once per instanced (duplicated) Gaussian ID.
__global__ void identifyTileRanges(int L, uint64_t* point_list_keys, uint2* ranges)
{
	auto idx = cg::this_grid().thread_rank();
	if (idx >= L)
		return;

	// Read tile ID from key. Update start/end of tile range if at limit.
	uint64_t key = point_list_keys[idx];
	uint32_t currtile = key >> 32;
	if (idx == 0)
		ranges[currtile].x = 0;
	else
	{
		uint32_t prevtile = point_list_keys[idx - 1] >> 32;
		if (currtile != prevtile)
		{
			ranges[prevtile].y = idx;
			ranges[currtile].x = idx;
		}
		if (idx == L - 1)
			ranges[currtile].y = L;
	}
}

CudaRasterizer::RasterizerImpl::RasterizerImpl(int resizeMultiplier)
	: resizeMultiplier(resizeMultiplier)
{}

// Instantiate rasterizer
CudaRasterizer::Rasterizer* CudaRasterizer::Rasterizer::make(int resizeMultiplier)
{
	return new CudaRasterizer::RasterizerImpl(resizeMultiplier);
}

// Mark Gaussians as visible/invisible, based on view frustum testing
void CudaRasterizer::RasterizerImpl::markVisible(
		int P,
		float* means3D,
		float* viewmatrix,
		float* projmatrix,
		bool* present)
{
	checkFrustum << <(P + 255) / 256, 256 >> > (
		P,
		means3D,
		viewmatrix, projmatrix,
		present);
}

// Forward rendering procedure for differentiable rasterization
// of Gaussians.
void CudaRasterizer::RasterizerImpl::forward(
	const int P, int D, int M,
	const float* background,
	const int width, int height,
	const float* means3D,
	const float* shs,
	const float* colors_precomp,
	const float* opacities,
	const float* scales,
	const float scale_modifier,
	const float* rotations,
	const float* cov3D_precomp,
	const float* viewmatrix,
	const float* projmatrix,
	const float* cam_pos,
	const float tan_fovx, float tan_fovy,
	const bool prefiltered,
	int* radii,
	InternalState* state,
	float* out_color)
{
	const float focal_y = height / (2.0f * tan_fovy);
	const float focal_x = width / (2.0f * tan_fovx);

	// Dynamically resize auxiliary buffers during training
	if (P > state->maxP)
	{
		state->maxP = resizeMultiplier * P;
		state->cov3D.resize(state->maxP * 6);
		state->rgb.resize(state->maxP * 3);
		state->tiles_touched.resize(state->maxP);
		state->point_offsets.resize(state->maxP);
		state->clamped.resize(3 * state->maxP);

		state->depths.resize(state->maxP);
		state->means2D.resize(state->maxP);
		state->conic_opacity.resize(state->maxP);

		size_t scan_size;
		cub::DeviceScan::InclusiveSum(nullptr, 
			scan_size, 
			state->tiles_touched.data().get(),
			state->tiles_touched.data().get(),
			state->maxP);
		state->scanning_space.resize(scan_size);
	}

	dim3 tile_grid((width + BLOCK_X - 1) / BLOCK_X, (height + BLOCK_Y - 1) / BLOCK_Y, 1);
	dim3 block(BLOCK_X, BLOCK_Y, 1);

	// Dynamically resize image-based auxiliary buffers during training
	if (width * height > state->maxPixels)
	{
		state->maxPixels = width * height;
		state->accum_alpha.resize(state->maxPixels);
		state->n_contrib.resize(state->maxPixels);
		state->ranges.resize(tile_grid.x * tile_grid.y);
	}

	if (NUM_CHANNELS != 3 && colors_precomp == nullptr)
	{
		throw std::runtime_error("For non-RGB, provide precomputed Gaussian colors!");
	}

	// Run preprocessing per-Gaussian (transformation, bounding, conversion of SHs to RGB)
	FORWARD::preprocess(
		P, D, M,
		means3D,
		(glm::vec3*)scales,
		scale_modifier,
		(glm::vec4*)rotations,
		opacities,
		shs,
		state->clamped.data().get(),
		cov3D_precomp,
		colors_precomp,
		viewmatrix, projmatrix,
		(glm::vec3*)cam_pos,
		width, height,
		tan_fovx, tan_fovy,
		focal_x, focal_y,
		radii,
		state->means2D.data().get(),
		state->depths.data().get(),
		state->cov3D.data().get(),
		state->rgb.data().get(),
		state->conic_opacity.data().get(),
		tile_grid,
		state->tiles_touched.data().get(),
		prefiltered
		);

	// Compute prefix sum over full list of touched tile counts by Gaussians
	// E.g., [2, 3, 0, 2, 1] -> [2, 5, 5, 7, 8]
	size_t scanning_space_size = state->scanning_space.size();
	cub::DeviceScan::InclusiveSum(
		state->scanning_space.data().get(),
		scanning_space_size,
		state->tiles_touched.data().get(),
		state->point_offsets.data().get(),
		P);

	// Retrieve total number of Gaussian instances to launch and resize aux buffers
	int num_needed;
	cudaMemcpy(&num_needed, state->point_offsets.data().get() + P - 1, sizeof(int), cudaMemcpyDeviceToHost);
	if (num_needed > point_list_keys_unsorted.size())
	{
		int resizeNum = resizeMultiplier * num_needed;
		point_list_keys_unsorted.resize(resizeNum);
		point_list_keys.resize(resizeNum);
		point_list_unsorted.resize(resizeNum);
		size_t sorting_size;
		cub::DeviceRadixSort::SortPairs(
			nullptr, sorting_size,
			point_list_keys_unsorted.data().get(), point_list_keys.data().get(),
			point_list_unsorted.data().get(), state->point_list.data().get(),
			resizeNum);
		list_sorting_space.resize(sorting_size);
	}

	if (num_needed > state->point_list.size())
	{
		state->point_list.resize(resizeMultiplier * num_needed);
	}

	// For each instance to be rendered, produce adequate [ tile | depth ] key 
	// and corresponding dublicated Gaussian indices to be sorted
	duplicateWithKeys << <(P + 255) / 256, 256 >> > (
		P, 
		state->means2D.data().get(),
		state->depths.data().get(),
		state->point_offsets.data().get(),
		point_list_keys_unsorted.data().get(), 
		point_list_unsorted.data().get(), 
		radii,
		tile_grid
		);

	int bit = getHigherMsb(tile_grid.x * tile_grid.y);

	// Sort complete list of (duplicated) Gaussian indices by keys
	size_t list_sorting_space_size = list_sorting_space.size();
	cub::DeviceRadixSort::SortPairs(
		list_sorting_space.data().get(),
		list_sorting_space_size,
		point_list_keys_unsorted.data().get(), point_list_keys.data().get(),
		point_list_unsorted.data().get(), 
		state->point_list.data().get(),
		num_needed, 0, 32 + bit);

	cudaMemset(state->ranges.data().get(), 0, tile_grid.x * tile_grid.y * sizeof(uint2));

	// Identify start and end of per-tile workloads in sorted list
	identifyTileRanges << <(num_needed + 255) / 256, 256 >> > ( 
		num_needed, 
		point_list_keys.data().get(), 
		state->ranges.data().get()
		);

	// Let each tile blend its range of Gaussians independently in parallel
	const float* feature_ptr = colors_precomp != nullptr ? colors_precomp : state->rgb.data().get();
	FORWARD::render(
		tile_grid, block,
		state->ranges.data().get(),
		state->point_list.data().get(),
		width, height,
		state->means2D.data().get(),
		feature_ptr,
		state->conic_opacity.data().get(),
		state->accum_alpha.data().get(),
		state->n_contrib.data().get(),
		background,
		out_color);
}

// Produce necessary gradients for optimization, corresponding
// to forward render pass
void CudaRasterizer::RasterizerImpl::backward(
	const int* radii,
	const InternalState* state,
	const int P, int D, int M,
	const float* background,
	const int width, int height,
	const float* means3D,
	const float* shs,
	const float* colors_precomp,
	const float* scales,
	const float scale_modifier,
	const float* rotations,
	const float* cov3D_precomp,
	const float* viewmatrix,
	const float* projmatrix,
	const float* campos,
	const float tan_fovx, float tan_fovy,
	const float* dL_dpix,
	float* dL_dmean2D,
	float* dL_dconic,
	float* dL_dopacity,
	float* dL_dcolor,
	float* dL_dmean3D,
	float* dL_dcov3D,
	float* dL_dsh,
	float* dL_dscale,
	float* dL_drot)
{
	const float focal_y = height / (2.0f * tan_fovy);
	const float focal_x = width / (2.0f * tan_fovx);

	const dim3 tile_grid((width + BLOCK_X - 1) / BLOCK_X, (height + BLOCK_Y - 1) / BLOCK_Y, 1);
	const dim3 block(BLOCK_X, BLOCK_Y, 1);

	// Compute loss gradients w.r.t. 2D mean position, conic matrix,
	// opacity and RGB of Gaussians from per-pixel loss gradients.
	// If we were given precomputed colors and not SHs, use them.
	const float* color_ptr = (colors_precomp != nullptr) ? colors_precomp : state->rgb.data().get();
	BACKWARD::render(
		tile_grid,
		block,
		state->ranges.data().get(),
		state->point_list.data().get(),
		width, height,
		background,
		state->means2D.data().get(),
		state->conic_opacity.data().get(),
		color_ptr,
		state->accum_alpha.data().get(),
		state->n_contrib.data().get(),
		dL_dpix,
		(float3*)dL_dmean2D,
		(float4*)dL_dconic,
		dL_dopacity,
		dL_dcolor);

	// Take care of the rest of preprocessing. Was the precomputed covariance
	// given to us or a scales/rot pair? If precomputed, pass that. If not,
	// use the one we computed ourselves.
	const float* cov3D_ptr = (cov3D_precomp != nullptr) ? cov3D_precomp : state->cov3D.data().get();
	BACKWARD::preprocess(P, D, M,
		(float3*)means3D, 
		radii,
		shs,
		state->clamped.data().get(),
		(glm::vec3*)scales,
		(glm::vec4*)rotations,
		scale_modifier,
		cov3D_ptr,
		viewmatrix,
		projmatrix,
		focal_x, focal_y,
		(glm::vec3*)campos,
		(float3*)dL_dmean2D,
		dL_dconic,
		(glm::vec3*)dL_dmean3D,
		dL_dcolor,
		dL_dcov3D,
		dL_dsh,
		(glm::vec3*)dL_dscale,
		(glm::vec4*)dL_drot);
}

CudaRasterizer::RasterizerImpl::~RasterizerImpl()
{
}