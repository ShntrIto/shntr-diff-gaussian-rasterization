/*
 * Copyright (C) 2023, Inria
 * GRAPHDECO research group, https://team.inria.fr/graphdeco
 * All rights reserved.
 *
 * This software is free for non-commercial, research and evaluation use 
 * under the terms of the LICENSE.md file.
 *
 * For inquiries contact  george.drettakis@inria.fr
 */

#include "backward.h"
#include "auxiliary.h"
#include <cooperative_groups.h>
#include <cooperative_groups/reduce.h>
namespace cg = cooperative_groups;

// Backward pass for conversion of spherical harmonics to RGB for
// each Gaussian.
__device__ void computeColorFromSH(int idx, int deg, int max_coeffs, const glm::vec3* means, glm::vec3 campos, const float* shs, const bool* clamped, const glm::vec3* dL_dcolor, glm::vec3* dL_dmeans, glm::vec3* dL_dshs)
{
	// Compute intermediate values, as it is done during forward
	glm::vec3 pos = means[idx];
	glm::vec3 dir_orig = pos - campos;
	glm::vec3 dir = dir_orig / glm::length(dir_orig);

	glm::vec3* sh = ((glm::vec3*)shs) + idx * max_coeffs;

	// Use PyTorch rule for clamping: if clamping was applied,
	// gradient becomes 0.
	glm::vec3 dL_dRGB = dL_dcolor[idx];
	dL_dRGB.x *= clamped[3 * idx + 0] ? 0 : 1;
	dL_dRGB.y *= clamped[3 * idx + 1] ? 0 : 1;
	dL_dRGB.z *= clamped[3 * idx + 2] ? 0 : 1;

	glm::vec3 dRGBdx(0, 0, 0);
	glm::vec3 dRGBdy(0, 0, 0);
	glm::vec3 dRGBdz(0, 0, 0);
	float x = dir.x;
	float y = dir.y;
	float z = dir.z;

	// Target location for this Gaussian to write SH gradients to
	glm::vec3* dL_dsh = dL_dshs + idx * max_coeffs;

	// No tricks here, just high school-level calculus.
	float dRGBdsh0 = SH_C0;
	dL_dsh[0] = dRGBdsh0 * dL_dRGB;
	if (deg > 0)
	{
		float dRGBdsh1 = -SH_C1 * y;
		float dRGBdsh2 = SH_C1 * z;
		float dRGBdsh3 = -SH_C1 * x;
		dL_dsh[1] = dRGBdsh1 * dL_dRGB;
		dL_dsh[2] = dRGBdsh2 * dL_dRGB;
		dL_dsh[3] = dRGBdsh3 * dL_dRGB;

		dRGBdx = -SH_C1 * sh[3];
		dRGBdy = -SH_C1 * sh[1];
		dRGBdz = SH_C1 * sh[2];

		if (deg > 1)
		{
			float xx = x * x, yy = y * y, zz = z * z;
			float xy = x * y, yz = y * z, xz = x * z;

			float dRGBdsh4 = SH_C2[0] * xy;
			float dRGBdsh5 = SH_C2[1] * yz;
			float dRGBdsh6 = SH_C2[2] * (2.f * zz - xx - yy);
			float dRGBdsh7 = SH_C2[3] * xz;
			float dRGBdsh8 = SH_C2[4] * (xx - yy);
			dL_dsh[4] = dRGBdsh4 * dL_dRGB;
			dL_dsh[5] = dRGBdsh5 * dL_dRGB;
			dL_dsh[6] = dRGBdsh6 * dL_dRGB;
			dL_dsh[7] = dRGBdsh7 * dL_dRGB;
			dL_dsh[8] = dRGBdsh8 * dL_dRGB;

			dRGBdx += SH_C2[0] * y * sh[4] + SH_C2[2] * 2.f * -x * sh[6] + SH_C2[3] * z * sh[7] + SH_C2[4] * 2.f * x * sh[8];
			dRGBdy += SH_C2[0] * x * sh[4] + SH_C2[1] * z * sh[5] + SH_C2[2] * 2.f * -y * sh[6] + SH_C2[4] * 2.f * -y * sh[8];
			dRGBdz += SH_C2[1] * y * sh[5] + SH_C2[2] * 2.f * 2.f * z * sh[6] + SH_C2[3] * x * sh[7];

			if (deg > 2)
			{
				float dRGBdsh9 = SH_C3[0] * y * (3.f * xx - yy);
				float dRGBdsh10 = SH_C3[1] * xy * z;
				float dRGBdsh11 = SH_C3[2] * y * (4.f * zz - xx - yy);
				float dRGBdsh12 = SH_C3[3] * z * (2.f * zz - 3.f * xx - 3.f * yy);
				float dRGBdsh13 = SH_C3[4] * x * (4.f * zz - xx - yy);
				float dRGBdsh14 = SH_C3[5] * z * (xx - yy);
				float dRGBdsh15 = SH_C3[6] * x * (xx - 3.f * yy);
				dL_dsh[9] = dRGBdsh9 * dL_dRGB;
				dL_dsh[10] = dRGBdsh10 * dL_dRGB;
				dL_dsh[11] = dRGBdsh11 * dL_dRGB;
				dL_dsh[12] = dRGBdsh12 * dL_dRGB;
				dL_dsh[13] = dRGBdsh13 * dL_dRGB;
				dL_dsh[14] = dRGBdsh14 * dL_dRGB;
				dL_dsh[15] = dRGBdsh15 * dL_dRGB;

				dRGBdx += (
					SH_C3[0] * sh[9] * 3.f * 2.f * xy +
					SH_C3[1] * sh[10] * yz +
					SH_C3[2] * sh[11] * -2.f * xy +
					SH_C3[3] * sh[12] * -3.f * 2.f * xz +
					SH_C3[4] * sh[13] * (-3.f * xx + 4.f * zz - yy) +
					SH_C3[5] * sh[14] * 2.f * xz +
					SH_C3[6] * sh[15] * 3.f * (xx - yy));

				dRGBdy += (
					SH_C3[0] * sh[9] * 3.f * (xx - yy) +
					SH_C3[1] * sh[10] * xz +
					SH_C3[2] * sh[11] * (-3.f * yy + 4.f * zz - xx) +
					SH_C3[3] * sh[12] * -3.f * 2.f * yz +
					SH_C3[4] * sh[13] * -2.f * xy +
					SH_C3[5] * sh[14] * -2.f * yz +
					SH_C3[6] * sh[15] * -3.f * 2.f * xy);

				dRGBdz += (
					SH_C3[1] * sh[10] * xy +
					SH_C3[2] * sh[11] * 4.f * 2.f * yz +
					SH_C3[3] * sh[12] * 3.f * (2.f * zz - xx - yy) +
					SH_C3[4] * sh[13] * 4.f * 2.f * xz +
					SH_C3[5] * sh[14] * (xx - yy));
			}
		}
	}

	// The view direction is an input to the computation. View direction
	// is influenced by the Gaussian's mean, so SHs gradients
	// must propagate back into 3D position.
	glm::vec3 dL_ddir(glm::dot(dRGBdx, dL_dRGB), glm::dot(dRGBdy, dL_dRGB), glm::dot(dRGBdz, dL_dRGB));

	// Account for normalization of direction
	float3 dL_dmean = dnormvdv(float3{ dir_orig.x, dir_orig.y, dir_orig.z }, float3{ dL_ddir.x, dL_ddir.y, dL_ddir.z });

	// Gradients of loss w.r.t. Gaussian means, but only the portion 
	// that is caused because the mean affects the view-dependent color.
	// Additional mean gradient is accumulated in below methods.
	dL_dmeans[idx] += glm::vec3(dL_dmean.x, dL_dmean.y, dL_dmean.z);
}

// // Backward version of INVERSE 2D covariance matrix computation
// // (due to length launched as separate kernel before other 
// // backward steps contained in preprocess)
// __global__ void computeCov2DCUDA(int P,
// 	const float3* means,
// 	const int* radii,
// 	const float* cov3Ds,
// 	const float h_x, float h_y,
// 	const float tan_fovx, float tan_fovy,
// 	const float* view_matrix,
// 	const float* dL_dconics,
// 	float3* dL_dmeans,
// 	float* dL_dcov)
// {
// 	auto idx = cg::this_grid().thread_rank();
// 	if (idx >= P || !(radii[idx] > 0))
// 		return;

// 	// Reading location of 3D covariance for this Gaussian
// 	const float* cov3D = cov3Ds + 6 * idx;

// 	// Fetch gradients, recompute 2D covariance and relevant 
// 	// intermediate forward results needed in the backward.
// 	float3 mean = means[idx];
// 	float3 dL_dconic = { dL_dconics[4 * idx], dL_dconics[4 * idx + 1], dL_dconics[4 * idx + 3] };
// 	float3 t = transformPoint4x3(mean, view_matrix);
	
// 	const float limx = 1.3f * tan_fovx;
// 	const float limy = 1.3f * tan_fovy;
// 	const float txtz = t.x / t.z;
// 	const float tytz = t.y / t.z;
// 	t.x = min(limx, max(-limx, txtz)) * t.z;
// 	t.y = min(limy, max(-limy, tytz)) * t.z;
	
// 	const float x_grad_mul = txtz < -limx || txtz > limx ? 0 : 1;
// 	const float y_grad_mul = tytz < -limy || tytz > limy ? 0 : 1;

// 	glm::mat3 J = glm::mat3(h_x / t.z, 0.0f, -(h_x * t.x) / (t.z * t.z),
// 		0.0f, h_y / t.z, -(h_y * t.y) / (t.z * t.z),
// 		0, 0, 0);

// 	glm::mat3 W = glm::mat3(
// 		view_matrix[0], view_matrix[4], view_matrix[8],
// 		view_matrix[1], view_matrix[5], view_matrix[9],
// 		view_matrix[2], view_matrix[6], view_matrix[10]);

// 	glm::mat3 Vrk = glm::mat3(
// 		cov3D[0], cov3D[1], cov3D[2],
// 		cov3D[1], cov3D[3], cov3D[4],
// 		cov3D[2], cov3D[4], cov3D[5]);

// 	glm::mat3 T = W * J;

// 	glm::mat3 cov2D = glm::transpose(T) * glm::transpose(Vrk) * T;

// 	// Use helper variables for 2D covariance entries. More compact.
// 	float a = cov2D[0][0] += 0.3f;
// 	float b = cov2D[0][1];
// 	float c = cov2D[1][1] += 0.3f;

// 	float denom = a * c - b * b;
// 	float dL_da = 0, dL_db = 0, dL_dc = 0;
// 	float denom2inv = 1.0f / ((denom * denom) + 0.0000001f);

// 	if (denom2inv != 0)
// 	{
// 		// Gradients of loss w.r.t. entries of 2D covariance matrix,
// 		// given gradients of loss w.r.t. conic matrix (inverse covariance matrix).
// 		// e.g., dL / da = dL / d_conic_a * d_conic_a / d_a
// 		dL_da = denom2inv * (-c * c * dL_dconic.x + 2 * b * c * dL_dconic.y + (denom - a * c) * dL_dconic.z);
// 		dL_dc = denom2inv * (-a * a * dL_dconic.z + 2 * a * b * dL_dconic.y + (denom - a * c) * dL_dconic.x);
// 		dL_db = denom2inv * 2 * (b * c * dL_dconic.x - (denom + 2 * b * b) * dL_dconic.y + a * b * dL_dconic.z);

// 		// Gradients of loss L w.r.t. each 3D covariance matrix (Vrk) entry, 
// 		// given gradients w.r.t. 2D covariance matrix (diagonal).
// 		// cov2D = transpose(T) * transpose(Vrk) * T;
// 		dL_dcov[6 * idx + 0] = (T[0][0] * T[0][0] * dL_da + T[0][0] * T[1][0] * dL_db + T[1][0] * T[1][0] * dL_dc);
// 		dL_dcov[6 * idx + 3] = (T[0][1] * T[0][1] * dL_da + T[0][1] * T[1][1] * dL_db + T[1][1] * T[1][1] * dL_dc);
// 		dL_dcov[6 * idx + 5] = (T[0][2] * T[0][2] * dL_da + T[0][2] * T[1][2] * dL_db + T[1][2] * T[1][2] * dL_dc);

// 		// Gradients of loss L w.r.t. each 3D covariance matrix (Vrk) entry, 
// 		// given gradients w.r.t. 2D covariance matrix (off-diagonal).
// 		// Off-diagonal elements appear twice --> double the gradient.
// 		// cov2D = transpose(T) * transpose(Vrk) * T;
// 		dL_dcov[6 * idx + 1] = 2 * T[0][0] * T[0][1] * dL_da + (T[0][0] * T[1][1] + T[0][1] * T[1][0]) * dL_db + 2 * T[1][0] * T[1][1] * dL_dc;
// 		dL_dcov[6 * idx + 2] = 2 * T[0][0] * T[0][2] * dL_da + (T[0][0] * T[1][2] + T[0][2] * T[1][0]) * dL_db + 2 * T[1][0] * T[1][2] * dL_dc;
// 		dL_dcov[6 * idx + 4] = 2 * T[0][2] * T[0][1] * dL_da + (T[0][1] * T[1][2] + T[0][2] * T[1][1]) * dL_db + 2 * T[1][1] * T[1][2] * dL_dc;
// 	}
// 	else
// 	{
// 		for (int i = 0; i < 6; i++)
// 			dL_dcov[6 * idx + i] = 0;
// 	}

// 	// Gradients of loss w.r.t. upper 2x3 portion of intermediate matrix T
// 	// cov2D = transpose(T) * transpose(Vrk) * T;
// 	float dL_dT00 = 2 * (T[0][0] * Vrk[0][0] + T[0][1] * Vrk[0][1] + T[0][2] * Vrk[0][2]) * dL_da +
// 		(T[1][0] * Vrk[0][0] + T[1][1] * Vrk[0][1] + T[1][2] * Vrk[0][2]) * dL_db;
// 	float dL_dT01 = 2 * (T[0][0] * Vrk[1][0] + T[0][1] * Vrk[1][1] + T[0][2] * Vrk[1][2]) * dL_da +
// 		(T[1][0] * Vrk[1][0] + T[1][1] * Vrk[1][1] + T[1][2] * Vrk[1][2]) * dL_db;
// 	float dL_dT02 = 2 * (T[0][0] * Vrk[2][0] + T[0][1] * Vrk[2][1] + T[0][2] * Vrk[2][2]) * dL_da +
// 		(T[1][0] * Vrk[2][0] + T[1][1] * Vrk[2][1] + T[1][2] * Vrk[2][2]) * dL_db;
// 	float dL_dT10 = 2 * (T[1][0] * Vrk[0][0] + T[1][1] * Vrk[0][1] + T[1][2] * Vrk[0][2]) * dL_dc +
// 		(T[0][0] * Vrk[0][0] + T[0][1] * Vrk[0][1] + T[0][2] * Vrk[0][2]) * dL_db;
// 	float dL_dT11 = 2 * (T[1][0] * Vrk[1][0] + T[1][1] * Vrk[1][1] + T[1][2] * Vrk[1][2]) * dL_dc +
// 		(T[0][0] * Vrk[1][0] + T[0][1] * Vrk[1][1] + T[0][2] * Vrk[1][2]) * dL_db;
// 	float dL_dT12 = 2 * (T[1][0] * Vrk[2][0] + T[1][1] * Vrk[2][1] + T[1][2] * Vrk[2][2]) * dL_dc +
// 		(T[0][0] * Vrk[2][0] + T[0][1] * Vrk[2][1] + T[0][2] * Vrk[2][2]) * dL_db;

// 	// Gradients of loss w.r.t. upper 3x2 non-zero entries of Jacobian matrix
// 	// T = W * J
// 	float dL_dJ00 = W[0][0] * dL_dT00 + W[0][1] * dL_dT01 + W[0][2] * dL_dT02;
// 	float dL_dJ02 = W[2][0] * dL_dT00 + W[2][1] * dL_dT01 + W[2][2] * dL_dT02;
// 	float dL_dJ11 = W[1][0] * dL_dT10 + W[1][1] * dL_dT11 + W[1][2] * dL_dT12;
// 	float dL_dJ12 = W[2][0] * dL_dT10 + W[2][1] * dL_dT11 + W[2][2] * dL_dT12;

// 	float tz = 1.f / t.z;
// 	float tz2 = tz * tz;
// 	float tz3 = tz2 * tz;

// 	// Gradients of loss w.r.t. transformed Gaussian mean t
// 	float dL_dtx = x_grad_mul * -h_x * tz2 * dL_dJ02;
// 	float dL_dty = y_grad_mul * -h_y * tz2 * dL_dJ12;
// 	float dL_dtz = -h_x * tz2 * dL_dJ00 - h_y * tz2 * dL_dJ11 + (2 * h_x * t.x) * tz3 * dL_dJ02 + (2 * h_y * t.y) * tz3 * dL_dJ12;

// 	// Account for transformation of mean to t
// 	// t = transformPoint4x3(mean, view_matrix);
// 	float3 dL_dmean = transformVec4x3Transpose({ dL_dtx, dL_dty, dL_dtz }, view_matrix);

// 	// Gradients of loss w.r.t. Gaussian means, but only the portion 
// 	// that is caused because the mean affects the covariance matrix.
// 	// Additional mean gradient is accumulated in BACKWARD::preprocess.
// 	dL_dmeans[idx] = dL_dmean;
// }

// Backward version of INVERSE 2D covariance matrix computation
// (due to length launched as separate kernel before other 
// backward steps contained in preprocess)
__global__ void computesphericalCov2DCUDA(int P,
	const float3* means,
	const int* radii,
	const float* cov3Ds,
	const float h_x, float h_y,
	const float* view_matrix,
	const float* dL_dconics,
	float3* dL_dmeans,
	float* dL_dcov,
	const int Height, // use Height for introducing Jacobian
	const int Width  // use Width as well
	)
{
	auto idx = cg::this_grid().thread_rank();
	if (idx >= P || !(radii[idx] > 0))
		return;

	// Reading location of 3D covariance for this Gaussian
	const float* cov3D = cov3Ds + 6 * idx;

	// Fetch gradients, recompute 2D covariance and relevant 
	// intermediate forward results needed in the backward.
	float3 mean = means[idx];
	float3 dL_dconic = { dL_dconics[4 * idx], dL_dconics[4 * idx + 1], dL_dconics[4 * idx + 3] };
    float3 t = transformPoint4x3(mean, view_matrix);
    
    // Useful veriables for spherical projection
	// float t_length = sqrtf(t.x * t.x + t.y * t.y + t.z * t.z);
	float tr = sqrtf(t.x * t.x + t.y * t.y + t.z * t.z);
	float tr2 = tr * tr;
	float tx2_ptz2 = t.x*t.x + t.z*t.z;

    // -------------------- ErpGS Jacobian --------------------
	glm::mat3 J = glm::mat3(
		( Width*t.z ) / ( M_PI*tx2_ptz2 ) * 0.5f, 					0.0f, 										-1.f * ( Width*t.x ) / ( M_PI*tx2_ptz2 ) * 0.5f,
		-1.f * ( Height*t.x*t.y ) / ( M_PI*tr2*sqrtf(tx2_ptz2) ), 	Height * sqrtf( tx2_ptz2 ) / ( M_PI*tr2 ), 	-1.f * ( Height*t.z*t.y ) / ( M_PI*tr2*sqrtf(tx2_ptz2) ),
		0.0f, 0.0f, 0.0f);
	// --------------------------------------------------------
	

	glm::mat3 W = glm::mat3(
		view_matrix[0], view_matrix[4], view_matrix[8],
		view_matrix[1], view_matrix[5], view_matrix[9],
		view_matrix[2], view_matrix[6], view_matrix[10]);

	glm::mat3 Vrk = glm::mat3(
		cov3D[0], cov3D[1], cov3D[2],
		cov3D[1], cov3D[3], cov3D[4],
		cov3D[2], cov3D[4], cov3D[5]);

	glm::mat3 T = W * J;

	glm::mat3 cov2D = glm::transpose(T) * glm::transpose(Vrk) * T;

	// Use helper variables for 2D covariance entries. More compact.
	float a = cov2D[0][0] += 0.3f;
	float b = cov2D[0][1];
	float c = cov2D[1][1] += 0.3f;

	float denom = a * c - b * b;
	float dL_da = 0, dL_db = 0, dL_dc = 0;
	float denom2inv = 1.0f / ((denom * denom) + 0.0000001f);

	if (denom2inv != 0)
	{
		// Gradients of loss w.r.t. entries of 2D covariance matrix,
		// given gradients of loss w.r.t. conic matrix (inverse covariance matrix).
		// e.g., dL / da = dL / d_conic_a * d_conic_a / d_a
		dL_da = denom2inv * (-c * c * dL_dconic.x + 2 * b * c * dL_dconic.y + (denom - a * c) * dL_dconic.z);
		dL_dc = denom2inv * (-a * a * dL_dconic.z + 2 * a * b * dL_dconic.y + (denom - a * c) * dL_dconic.x);
		dL_db = denom2inv * 2 * (b * c * dL_dconic.x - (denom + 2 * b * b) * dL_dconic.y + a * b * dL_dconic.z);

		// Gradients of loss L w.r.t. each 3D covariance matrix (Vrk) entry, 
		// given gradients w.r.t. 2D covariance matrix (diagonal).
		// cov2D = transpose(T) * transpose(Vrk) * T;
		dL_dcov[6 * idx + 0] = (T[0][0] * T[0][0] * dL_da + T[0][0] * T[1][0] * dL_db + T[1][0] * T[1][0] * dL_dc);
		dL_dcov[6 * idx + 3] = (T[0][1] * T[0][1] * dL_da + T[0][1] * T[1][1] * dL_db + T[1][1] * T[1][1] * dL_dc);
		dL_dcov[6 * idx + 5] = (T[0][2] * T[0][2] * dL_da + T[0][2] * T[1][2] * dL_db + T[1][2] * T[1][2] * dL_dc);

		// Gradients of loss L w.r.t. each 3D covariance matrix (Vrk) entry, 
		// given gradients w.r.t. 2D covariance matrix (off-diagonal).
		// Off-diagonal elements appear twice --> double the gradient.
		// cov2D = transpose(T) * transpose(Vrk) * T;
		dL_dcov[6 * idx + 1] = 2 * T[0][0] * T[0][1] * dL_da + (T[0][0] * T[1][1] + T[0][1] * T[1][0]) * dL_db + 2 * T[1][0] * T[1][1] * dL_dc;
		dL_dcov[6 * idx + 2] = 2 * T[0][0] * T[0][2] * dL_da + (T[0][0] * T[1][2] + T[0][2] * T[1][0]) * dL_db + 2 * T[1][0] * T[1][2] * dL_dc;
		dL_dcov[6 * idx + 4] = 2 * T[0][2] * T[0][1] * dL_da + (T[0][1] * T[1][2] + T[0][2] * T[1][1]) * dL_db + 2 * T[1][1] * T[1][2] * dL_dc;
	}
	else
	{
		for (int i = 0; i < 6; i++)
			dL_dcov[6 * idx + i] = 0;
	}

	// Gradients of loss w.r.t. upper 2x3 portion of intermediate matrix T
	// cov2D = transpose(T) * transpose(Vrk) * T;
	float dL_dT00 = 2 * (T[0][0] * Vrk[0][0] + T[0][1] * Vrk[0][1] + T[0][2] * Vrk[0][2]) * dL_da +
		(T[1][0] * Vrk[0][0] + T[1][1] * Vrk[0][1] + T[1][2] * Vrk[0][2]) * dL_db;
	float dL_dT01 = 2 * (T[0][0] * Vrk[1][0] + T[0][1] * Vrk[1][1] + T[0][2] * Vrk[1][2]) * dL_da +
		(T[1][0] * Vrk[1][0] + T[1][1] * Vrk[1][1] + T[1][2] * Vrk[1][2]) * dL_db;
	float dL_dT02 = 2 * (T[0][0] * Vrk[2][0] + T[0][1] * Vrk[2][1] + T[0][2] * Vrk[2][2]) * dL_da +
		(T[1][0] * Vrk[2][0] + T[1][1] * Vrk[2][1] + T[1][2] * Vrk[2][2]) * dL_db;
	float dL_dT10 = 2 * (T[1][0] * Vrk[0][0] + T[1][1] * Vrk[0][1] + T[1][2] * Vrk[0][2]) * dL_dc +
		(T[0][0] * Vrk[0][0] + T[0][1] * Vrk[0][1] + T[0][2] * Vrk[0][2]) * dL_db;
	float dL_dT11 = 2 * (T[1][0] * Vrk[1][0] + T[1][1] * Vrk[1][1] + T[1][2] * Vrk[1][2]) * dL_dc +
		(T[0][0] * Vrk[1][0] + T[0][1] * Vrk[1][1] + T[0][2] * Vrk[1][2]) * dL_db;
	float dL_dT12 = 2 * (T[1][0] * Vrk[2][0] + T[1][1] * Vrk[2][1] + T[1][2] * Vrk[2][2]) * dL_dc +
		(T[0][0] * Vrk[2][0] + T[0][1] * Vrk[2][1] + T[0][2] * Vrk[2][2]) * dL_db;

	// Gradients of loss w.r.t. upper 3x2 non-zero entries of Jacobian matrix
	// T = W * J
	float dL_dJ00 = W[0][0] * dL_dT00 + W[0][1] * dL_dT01 + W[0][2] * dL_dT02;
	float dL_dJ02 = W[2][0] * dL_dT00 + W[2][1] * dL_dT01 + W[2][2] * dL_dT02;
	float dL_dJ10 = W[0][0] * dL_dT10 + W[0][1] * dL_dT11 + W[0][2] * dL_dT12; // Add OmniGS Jacobian
	float dL_dJ11 = W[1][0] * dL_dT10 + W[1][1] * dL_dT11 + W[1][2] * dL_dT12;
	float dL_dJ12 = W[2][0] * dL_dT10 + W[2][1] * dL_dT11 + W[2][2] * dL_dT12;

	// Useful variables for ErpGS Gradients
	// float rec_tr = 1.f / tr;  			// 1/tr
	// float rec_tr2 = rec_tr * rec_tr; 	// 1/(tr^2)
	// float rec_tr4 = rec_tr2 * rec_tr2; 	// 1/(tr^4)
	float tx2 = t.x * t.x; 				// tx^2
	float tz2 = t.z * t.z; 				// tz^2
	float tx2tz2 = tx2 + tz2; 			// tx^2 + tz^2
	float sqrt_tx2tz2 = sqrtf(tx2tz2); 	// sqrt(tx^2 + tz^2)
	
	// ------------------ ErpGS ------------------
	// Gradients of loss w.r.t. transformed Gaussian mean t
	float dL_dtx = -Width*t.x*t.z / ( M_PI * tx2tz2*tx2tz2) * dL_dJ00 +
					-Width * ( tz2 + 3.f*tx2 ) / ( 2.f* M_PI * tx2tz2*tx2tz2 ) * dL_dJ02 +
					-Height * ( 2.f*tx2 + tz2) / ( M_PI * tr2 * tx2tz2*sqrt_tx2tz2 ) * dL_dJ10 +
					-Height*t.x / ( M_PI * tr2 * tx2tz2*sqrt_tx2tz2 ) * dL_dJ11 +
					Height*t.x*t.y*t.z / ( M_PI * tr2 * tx2tz2*sqrt_tx2tz2 ) * dL_dJ12;
	
	float dL_dty = -Height*t.x / (M_PI * tr2 * sqrt_tx2tz2 ) * dL_dJ10 +
					-Height*t.z / (M_PI * tr2 * sqrt_tx2tz2 ) * dL_dJ12;
	
	float dL_dtz = Width * ( tx2 + 3.f*tz2 ) / ( 2.f*M_PI * tx2tz2*tx2tz2 ) * dL_dJ00 +
					Width*t.x*t.z / ( M_PI * tx2tz2*tx2tz2 ) * dL_dJ02 +
					Height*t.x*t.y*t.z / ( M_PI * tr2 * tx2tz2*sqrt_tx2tz2 ) * dL_dJ10 +
					Height*tz2 / ( M_PI * tr2 * sqrt_tx2tz2 ) * dL_dJ11 +
					-Height*t.y * (tx2 + 2.f*tz2) / (M_PI * tr2 * tx2tz2*sqrt_tx2tz2 ) * dL_dJ12;
	// -------------------------------------------



	// -------------------- ODGS ------------------
	// float dL_dtx = -1.f*Width * ( t.x*t.z ) / (M_PI * tx2tz2 * tx2tz2) * dL_dJ00 +
	// 				Width * (tx2 - tz2) / ( 2.f * M_PI * tx2tz2 * tx2tz2 ) * dL_dJ02 +
	// 				Height*t.y * ( tz2*tr2 - 2.f * tx2 * tx2tz2 ) / ( M_PI * tr4 * tx2tz2*sqrt_tx2tz2 ) * dL_dJ10 +
	// 				Height*t.x * ( tr2 - 2.f*ty2 ) / (M_PI * tr4 * sqrt_tx2tz2) * dL_dJ11 +
	// 				-1.f*Height*t.x*t.y*t.z * ( 2.f*tx2tz2 + tr2 ) / ( M_PI * tr4 * tx2tz2*sqrt_tx2tz2 ) * dL_dJ12;
	
	// float dL_dty = Height*t.x * ( tr2 - 2.f*ty2) / ( M_PI * tr4 * tx2tz2*sqrt_tx2tz2 ) * dL_dJ10 +
	// 				2.f*Height*t.y*sqrt_tx2tz2 / ( M_PI * tr4 ) * dL_dJ11 +
	// 				Height*t.z *( tr2 - 2.f*ty2 ) / ( M_PI * tr4 * sqrt_tx2tz2 ) * dL_dJ12;
	
	// float dL_dtz = Width * ( tx2 - tz2 ) / ( 2.f*M_PI * tx2tz2*tx2tz2) * dL_dJ00 +
	// 				Width*t.x*t.z / ( M_PI * tx2tz2*tx2tz2 ) * dL_dJ02 +
	// 				-1.f*Height*t.x*t.y*t.z * ( 2.f*tx2tz2 + tr2 ) / ( M_PI * tr4 * tx2tz2*sqrt_tx2tz2 ) * dL_dJ10 +
	// 				Height*t.z * ( tr2 - 2.f*ty2 ) / ( M_PI * tr4 * sqrt_tx2tz2 ) * dL_dJ11 +
	// 				Height*t.y * (tx2*tr2 - 2.f*tz2*tx2tz2 ) / (M_PI * tr4 * tx2tz2*sqrt_tx2tz2 ) * dL_dJ12;
	// -------------------------------------------

	// float dL_dtx =  (-1.f*Width*t.x*t.z)/(M_PI*tx2_ptz2*tx2_ptz2) * dL_dJ00 + 
	// 				(Width*tx2_mtz2)/(2.f*M_PI*tx2_ptz2*tx2_ptz2) * dL_dJ02 +
	// 				(Hight*t.y*tr2)/(M_PI*sqrtf(tx2_ptz2)) * ((2.f*t.x*t.x*tr2 + (t.x*t.x)/tx2_ptz2 - 1.f)) * dL_dJ10 + 
	// 				(Hight*t.x*tr2)/M_PI * (1.f/sqrtf(tx2_ptz2) - (2.f*sqrtf(tx2_ptz2)/tr2)) * dL_dJ11 +
	// 				(Hight*t.x*t.y*t.z*tr2)/(M_PI*sqrtf(tx2_ptz2)) * ((2.f*tr2)/sqrtf(tx2_ptz2) + 1.f/tx2_ptz2) * dL_dJ12;
	// float dL_dty =  (Hight*t.x*tr2)/(M_PI*sqrtf(tx2_ptz2)) * (2.f*t.y*t.y*tr2 - 1.f) * dL_dJ10 +
	// 				(-2.f*Hight*t.y*sqrtf(tx2_ptz2)*tr4)/M_PI * dL_dJ11 + 
	// 				(-1.f*Hight*tz)/(M_PI*sqrtf(tx2_ptz2)) * (tr2-2.f*t.y*t.y*tr2) * dL_dJ12;
	// float dL_dtz =  (Width*tx2_mtz2)/(2.f*M_PI*(tx2_ptz2)) * dL_dJ00 +
	// 				(Width*t.x*t.z)/(M_PI*tx2_ptz2*tx2_ptz2) * dL_dJ02 +
	// 				(Hight*t.x*t.y*t.z*tr2)/(M_PI*sqrt(tx2_ptz2)) * (2.f*tr2+1.f/tx2_ptz2) * dL_dJ10 +
	// 				(Hight*t.z*tr2)/(M_PI*sqrtf(tx2_ptz2)) * (1.f-2.f*tx2_ptz2*tr2) * dL_dJ11 +
	// 				(-1.f*Hight*t.y*tr2)/(M_PI*sqrtf(tx2_ptz2)) * (1.f-2.f*t.z*t.z*tr2+t.z*t.z/tx2_ptz2) * dL_dJ12;
	// -------------------------------------------


	// Account for transformation of mean to t
	// t = transformPoint4x3(mean, view_matrix);
	float3 dL_dmean = transformVec4x3Transpose({ dL_dtx, dL_dty, dL_dtz }, view_matrix);

	// Gradients of loss w.r.t. Gaussian means, but only the portion 
	// that is caused because the mean affects the covariance matrix.
	// Additional mean gradient is accumulated in BACKWARD::preprocess.
	dL_dmeans[idx] = dL_dmean;
}

// Backward pass for the conversion of scale and rotation to a 
// 3D covariance matrix for each Gaussian. 
__device__ void computeCov3D(int idx, const glm::vec3 scale, float mod, const glm::vec4 rot, const float* dL_dcov3Ds, glm::vec3* dL_dscales, glm::vec4* dL_drots)
{
	// Recompute (intermediate) results for the 3D covariance computation.
	glm::vec4 q = rot;// / glm::length(rot);
	float r = q.x;
	float x = q.y;
	float y = q.z;
	float z = q.w;

	glm::mat3 R = glm::mat3(
		1.f - 2.f * (y * y + z * z), 2.f * (x * y - r * z), 2.f * (x * z + r * y),
		2.f * (x * y + r * z), 1.f - 2.f * (x * x + z * z), 2.f * (y * z - r * x),
		2.f * (x * z - r * y), 2.f * (y * z + r * x), 1.f - 2.f * (x * x + y * y)
	);

	glm::mat3 S = glm::mat3(1.0f);

	glm::vec3 s = mod * scale;
	S[0][0] = s.x;
	S[1][1] = s.y;
	S[2][2] = s.z;

	glm::mat3 M = S * R;

	const float* dL_dcov3D = dL_dcov3Ds + 6 * idx;

	glm::vec3 dunc(dL_dcov3D[0], dL_dcov3D[3], dL_dcov3D[5]);
	glm::vec3 ounc = 0.5f * glm::vec3(dL_dcov3D[1], dL_dcov3D[2], dL_dcov3D[4]);

	// Convert per-element covariance loss gradients to matrix form
	glm::mat3 dL_dSigma = glm::mat3(
		dL_dcov3D[0], 0.5f * dL_dcov3D[1], 0.5f * dL_dcov3D[2],
		0.5f * dL_dcov3D[1], dL_dcov3D[3], 0.5f * dL_dcov3D[4],
		0.5f * dL_dcov3D[2], 0.5f * dL_dcov3D[4], dL_dcov3D[5]
	);

	// Compute loss gradient w.r.t. matrix M
	// dSigma_dM = 2 * M
	glm::mat3 dL_dM = 2.0f * M * dL_dSigma;

	glm::mat3 Rt = glm::transpose(R);
	glm::mat3 dL_dMt = glm::transpose(dL_dM);

	// Gradients of loss w.r.t. scale
	glm::vec3* dL_dscale = dL_dscales + idx;
	dL_dscale->x = glm::dot(Rt[0], dL_dMt[0]);
	dL_dscale->y = glm::dot(Rt[1], dL_dMt[1]);
	dL_dscale->z = glm::dot(Rt[2], dL_dMt[2]);

	dL_dMt[0] *= s.x;
	dL_dMt[1] *= s.y;
	dL_dMt[2] *= s.z;

	// Gradients of loss w.r.t. normalized quaternion
	glm::vec4 dL_dq;
	dL_dq.x = 2 * z * (dL_dMt[0][1] - dL_dMt[1][0]) + 2 * y * (dL_dMt[2][0] - dL_dMt[0][2]) + 2 * x * (dL_dMt[1][2] - dL_dMt[2][1]);
	dL_dq.y = 2 * y * (dL_dMt[1][0] + dL_dMt[0][1]) + 2 * z * (dL_dMt[2][0] + dL_dMt[0][2]) + 2 * r * (dL_dMt[1][2] - dL_dMt[2][1]) - 4 * x * (dL_dMt[2][2] + dL_dMt[1][1]);
	dL_dq.z = 2 * x * (dL_dMt[1][0] + dL_dMt[0][1]) + 2 * r * (dL_dMt[2][0] - dL_dMt[0][2]) + 2 * z * (dL_dMt[1][2] + dL_dMt[2][1]) - 4 * y * (dL_dMt[2][2] + dL_dMt[0][0]);
	dL_dq.w = 2 * r * (dL_dMt[0][1] - dL_dMt[1][0]) + 2 * x * (dL_dMt[2][0] + dL_dMt[0][2]) + 2 * y * (dL_dMt[1][2] + dL_dMt[2][1]) - 4 * z * (dL_dMt[1][1] + dL_dMt[0][0]);

	// Gradients of loss w.r.t. unnormalized quaternion
	float4* dL_drot = (float4*)(dL_drots + idx);
	*dL_drot = float4{ dL_dq.x, dL_dq.y, dL_dq.z, dL_dq.w };//dnormvdv(float4{ rot.x, rot.y, rot.z, rot.w }, float4{ dL_dq.x, dL_dq.y, dL_dq.z, dL_dq.w });
}

// // Backward pass of the preprocessing steps, except
// // for the covariance computation and inversion
// // (those are handled by a previous kernel call)
// template<int C>
// __global__ void preprocessCUDA(
// 	int P, int D, int M,
// 	const float3* means,
// 	const int* radii,
// 	const float* shs,
// 	const bool* clamped,
// 	const glm::vec3* scales,
// 	const glm::vec4* rotations,
// 	const float scale_modifier,
// 	const float* proj,
// 	const glm::vec3* campos,
// 	const float3* dL_dmean2D,
// 	glm::vec3* dL_dmeans,
// 	float* dL_dcolor,
// 	float* dL_dcov3D,
// 	float* dL_dsh,
// 	glm::vec3* dL_dscale,
// 	glm::vec4* dL_drot)
// {
// 	auto idx = cg::this_grid().thread_rank();
// 	if (idx >= P || !(radii[idx] > 0))
// 		return;

// 	float3 m = means[idx];

// 	// Taking care of gradients from the screenspace points
// 	float4 m_hom = transformPoint4x4(m, proj);
// 	float m_w = 1.0f / (m_hom.w + 0.0000001f);

// 	// Compute loss gradient w.r.t. 3D means due to gradients of 2D means
// 	// from rendering procedure
// 	glm::vec3 dL_dmean;
// 	float mul1 = (proj[0] * m.x + proj[4] * m.y + proj[8] * m.z + proj[12]) * m_w * m_w; // m_hom.x * m_w * m_w
// 	float mul2 = (proj[1] * m.x + proj[5] * m.y + proj[9] * m.z + proj[13]) * m_w * m_w; // m_hom_y * m_w * m_w
// 	dL_dmean.x = (proj[0] * m_w - proj[3] * mul1) * dL_dmean2D[idx].x + (proj[1] * m_w - proj[3] * mul2) * dL_dmean2D[idx].y;
// 	dL_dmean.y = (proj[4] * m_w - proj[7] * mul1) * dL_dmean2D[idx].x + (proj[5] * m_w - proj[7] * mul2) * dL_dmean2D[idx].y;
// 	dL_dmean.z = (proj[8] * m_w - proj[11] * mul1) * dL_dmean2D[idx].x + (proj[9] * m_w - proj[11] * mul2) * dL_dmean2D[idx].y;

// 	// That's the second part of the mean gradient. Previous computation
// 	// of cov2D and following SH conversion also affects it.
// 	dL_dmeans[idx] += dL_dmean;

// 	// Compute gradient updates due to computing colors from SHs
// 	if (shs)
// 		computeColorFromSH(idx, D, M, (glm::vec3*)means, *campos, shs, clamped, (glm::vec3*)dL_dcolor, (glm::vec3*)dL_dmeans, (glm::vec3*)dL_dsh);

// 	// Compute gradient updates due to computing covariance from scale/rotation
// 	if (scales)
// 		computeCov3D(idx, scales[idx], scale_modifier, rotations[idx], dL_dcov3D, dL_dscale, dL_drot);
// }

// Backward pass of the preprocessing steps, except
// for the covariance computation and inversion
// (those are handled by a previous kernel call)
template<int C>
__global__ void preprocesssphericalCUDA(
	int P, int D, int M,
	const float3* means,
	const int* radii,
	const float* shs,
	const bool* clamped,
	const glm::vec3* scales,
	const glm::vec4* rotations,
	const float scale_modifier,
	const float* view_matrix,
	const float* proj,
	const glm::vec3* campos,
	const float3* dL_dmean2D,
	glm::vec3* dL_dmeans,
	float* dL_dcolor,
	float* dL_dcov3D,
	float* dL_dsh,
	glm::vec3* dL_dscale,
	glm::vec4* dL_drot,
	const float* dL_dconics, // Add for OmniGS
	const int Hight, // Add for OmniGS
	const int Width  // Add for OmniGS
	)
{
	auto idx = cg::this_grid().thread_rank();
	if (idx >= P || !(radii[idx] > 0))
		return;

	float3 m = means[idx];

	// Taking care of gradients from the screenspace points
	// float4 m_hom = transformPoint4x4(m, proj);
	// float m_w = 1.0f / (m_hom.w + 0.0000001f);

	// Compute loss gradient w.r.t. 3D means due to gradients of 2D means
	// from rendering procedure
	// glm::vec3 dL_dmean;
	// float mul1 = (proj[0] * m.x + proj[4] * m.y + proj[8] * m.z + proj[12]) * m_w * m_w; // m_hom.x * m_w * m_w = tx/tz
	// float mul2 = (proj[1] * m.x + proj[5] * m.y + proj[9] * m.z + proj[13]) * m_w * m_w; // m_hom.y * m_w * m_w = ty/tz
	// dL_dmean.x = (proj[0] * m_w - proj[3] * mul1) * dL_dmean2D[idx].x + (proj[1] * m_w - proj[3] * mul2) * dL_dmean2D[idx].y;
	// dL_dmean.y = (proj[4] * m_w - proj[7] * mul1) * dL_dmean2D[idx].x + (proj[5] * m_w - proj[7] * mul2) * dL_dmean2D[idx].y;
	// dL_dmean.z = (proj[8] * m_w - proj[11] * mul1) * dL_dmean2D[idx].x + (proj[9] * m_w - proj[11] * mul2) * dL_dmean2D[idx].y;

	// ******************
	// Re-compute Jacobian for trial

	// Fetch gradients, recompute 2D covariance and relevant 
	// intermediate forward results needed in the backward.
	float3 dL_dconic = { dL_dconics[4 * idx], dL_dconics[4 * idx + 1], dL_dconics[4 * idx + 3] };
    float3 t = transformPoint4x3(m, view_matrix);
    
    // Useful veriables for spherical projection
	float tr = sqrtf(t.x * t.x + t.y * t.y + t.z * t.z);
	float tr2 = tr * tr;
	float tx2_ptz2 = t.x*t.x + t.z*t.z;

    // -------------------- ErpGS Jacobian --------------------
	glm::mat3 J = glm::mat3(
		( Width*t.z ) / ( M_PI*tx2_ptz2 ) * 0.5f, 					0.0f, 										-1.f * ( Width*t.x ) / ( M_PI*tx2_ptz2 ) * 0.5f,
		-1.f * ( Hight*t.x*t.y ) / ( M_PI*tr2*sqrtf(tx2_ptz2) ), 	Hight * sqrtf( tx2_ptz2 ) / ( M_PI*tr2 ), 	-1.f * ( Hight*t.z*t.y ) / ( M_PI*tr2*sqrtf(tx2_ptz2) ),
		0.0f, 0.0f, 0.0f);
	// --------------------------------------------------------

	// Compute loss gradient w.r.t. 3D means due to gradients of 2D means
	// OmniGS version
	glm::vec3 dL_dmean;
	dL_dmean.x = J[0][0] * dL_dmean2D[idx].x + J[1][0] * dL_dmean2D[idx].y;
	dL_dmean.y = J[0][1] * dL_dmean2D[idx].x + J[1][1] * dL_dmean2D[idx].y;
	dL_dmean.z = J[0][2] * dL_dmean2D[idx].x + J[1][2] * dL_dmean2D[idx].y;

	// That's the second part of the mean gradient. Previous computation
	// of cov2D and following SH conversion also affects it.
	dL_dmeans[idx] += dL_dmean;

	// Compute gradient updates due to computing colors from SHs
	if (shs)
		computeColorFromSH(idx, D, M, (glm::vec3*)means, *campos, shs, clamped, (glm::vec3*)dL_dcolor, (glm::vec3*)dL_dmeans, (glm::vec3*)dL_dsh);

	// Compute gradient updates due to computing covariance from scale/rotation
	if (scales)
		computeCov3D(idx, scales[idx], scale_modifier, rotations[idx], dL_dcov3D, dL_dscale, dL_drot);
}


// Backward version of the rendering procedure.
template <uint32_t C, uint32_t MODAL_N>
__global__ void __launch_bounds__(BLOCK_X * BLOCK_Y)
renderCUDA(
	const uint2* __restrict__ ranges,
	const uint32_t* __restrict__ point_list,
	int W, int H,
	const float* __restrict__ bg_color,
	const float2* __restrict__ points_xy_image,
	const float4* __restrict__ conic_opacity,
	const float* __restrict__ colors,
	const float* __restrict__ all_modals, // modalities
	const float* __restrict__ all_modal_pixels, // modalities
	const float* __restrict__ final_Ts,
	const uint32_t* __restrict__ n_contrib,
	const float* __restrict__ dL_dpixels,
	const float* __restrict__ dL_dout_all_modals, // modalities
	const float* __restrict__ dL_dout_plane_depths, // modalities
	float3* __restrict__ dL_dmean2D,
	float4* __restrict__ dL_dconic2D,
	float* __restrict__ dL_dopacity,
	float* __restrict__ dL_dcolors,
	float* __restrict__ dL_dall_modal) // modalities
{
	// We rasterize again. Compute necessary block info.
	auto block = cg::this_thread_block();
	const uint32_t horizontal_blocks = (W + BLOCK_X - 1) / BLOCK_X;
	const uint2 pix_min = { block.group_index().x * BLOCK_X, block.group_index().y * BLOCK_Y };
	const uint2 pix_max = { min(pix_min.x + BLOCK_X, W), min(pix_min.y + BLOCK_Y , H) };
	const uint2 pix = { pix_min.x + block.thread_index().x, pix_min.y + block.thread_index().y };
	const uint32_t pix_id = W * pix.y + pix.x;
	const float2 pixf = { (float)pix.x, (float)pix.y };
	const float2 sphere_pos = { 2.0f*M_PI*(pix.x -0.5f*W)/W, M_PI*(0.5f*H - pix.y)/H };
	const float3 ray = { cosf(sphere_pos.y)*sinf(sphere_pos.x), -sinf(sphere_pos.y), cosf(sphere_pos.y)*cosf(sphere_pos.x) };

	const bool inside = pix.x < W&& pix.y < H;
	const uint2 range = ranges[block.group_index().y * horizontal_blocks + block.group_index().x];

	const int rounds = ((range.y - range.x + BLOCK_SIZE - 1) / BLOCK_SIZE);

	bool done = !inside;
	int toDo = range.y - range.x;

	__shared__ int collected_id[BLOCK_SIZE];
	__shared__ float2 collected_xy[BLOCK_SIZE];
	__shared__ float4 collected_conic_opacity[BLOCK_SIZE];
	__shared__ float collected_colors[C * BLOCK_SIZE];
	__shared__ float collected_all_modals[MODAL_N * BLOCK_SIZE]; // modalities

	// In the forward, we stored the final value for T, the
	// product of all (1 - alpha) factors. 
	const float T_final = inside ? final_Ts[pix_id] : 0;
	float T = T_final;

	// We start from the back. The ID of the last contributing
	// Gaussian is known from each pixel from the forward.
	uint32_t contributor = toDo;
	const int last_contributor = inside ? n_contrib[pix_id] : 0;

	float accum_rec[C] = { 0 };
	float accum_all_modal[MODAL_N] = { 0 }; // modalities
	float dL_dpixel[C];
	float dL_dout_all_modal[MODAL_N]; // modalities
	if (inside)
		for (int i = 0; i < C; i++)
			dL_dpixel[i] = dL_dpixels[i * H * W + pix_id];
		for (int i = 0; i < MODAL_N; i++)
			dL_dout_all_modal[i] = dL_dout_all_modals[i * H * W + pix_id]; // modalities

		const float3 normal = {all_modal_pixels[pix_id], all_modal_pixels[H * W + pix_id], all_modal_pixels[2 * H * W + pix_id]};
		const float distance = all_modal_pixels[4 * H * W + pix_id];
		const float tmp = (normal.x * ray.x + normal.y * ray.y + normal.z * ray.z + 1.0e-8);
		dL_dout_all_modal[MODAL_N-1] += (-dL_dout_plane_depths[pix_id] / tmp);
		dL_dout_all_modal[0] += dL_dout_plane_depths[pix_id] * (distance / (tmp * tmp) * ray.x);
		dL_dout_all_modal[1] += dL_dout_plane_depths[pix_id] * (distance / (tmp * tmp) * ray.y);
		dL_dout_all_modal[2] += dL_dout_plane_depths[pix_id] * (distance / (tmp * tmp) * ray.z);

	float last_alpha = 0;
	float last_color[C] = { 0 };
	float last_all_modal[MODAL_N] = { 0 }; // modalities

	// ------------------ ErpGS ------------------
	// Gradient of pixel coordinate w.r.t. normalized 
	// screen-space viewport corrdinates (-1 to 1)
	const float ddelx_dx = 0.5 * W; 
	const float ddely_dy = 0.5 * H;
	// -------------------------------------------

	// ------------------ ErpGS ------------------
	// Gradient of pixel coordinate w.r.t. omnidirectional
	// screen-space viewport coordinates
	// (-pi to pi for horizontal, -pi/2 to pi/2 for vertical)

	// const float ddelx_dx = W / (2 * M_PI); 
	// const float ddely_dy = H / M_PI;
	// -------------------------------------------

	// Traverse all Gaussians
	for (int i = 0; i < rounds; i++, toDo -= BLOCK_SIZE)
	{
		// Load auxiliary data into shared memory, start in the BACK
		// and load them in revers order.
		block.sync();
		const int progress = i * BLOCK_SIZE + block.thread_rank();
		if (range.x + progress < range.y)
		{
			const int coll_id = point_list[range.y - progress - 1];
			collected_id[block.thread_rank()] = coll_id;
			collected_xy[block.thread_rank()] = points_xy_image[coll_id];
			collected_conic_opacity[block.thread_rank()] = conic_opacity[coll_id];
			for (int i = 0; i < C; i++)
				collected_colors[i * BLOCK_SIZE + block.thread_rank()] = colors[coll_id * C + i];
			for (int i = 0; i < MODAL_N; i++)
				collected_all_modals[i * BLOCK_SIZE + block.thread_rank()] = all_modals[coll_id * MODAL_N + i]; // modalities
		}
		block.sync();

		// Iterate over Gaussians
		for (int j = 0; !done && j < min(BLOCK_SIZE, toDo); j++)
		{
			// Keep track of current Gaussian ID. Skip, if this one
			// is behind the last contributor for this pixel.
			contributor--;
			if (contributor >= last_contributor)
				continue;

			// Compute blending values, as before.
			const float2 xy = collected_xy[j];
			const float2 d = { xy.x - pixf.x, xy.y - pixf.y };
			const float4 con_o = collected_conic_opacity[j];
			const float power = -0.5f * (con_o.x * d.x * d.x + con_o.z * d.y * d.y) - con_o.y * d.x * d.y;
			if (power > 0.0f)
				continue;

			const float G = exp(power);
			const float alpha = min(0.99f, con_o.w * G);
			if (alpha < 1.0f / 255.0f)
				continue;

			T = T / (1.f - alpha);
			const float dchannel_dcolor = alpha * T;
			const float dchannel_ddepth = alpha * T; // depth

			// Propagate gradients to per-Gaussian colors and keep
			// gradients w.r.t. alpha (blending factor for a Gaussian/pixel
			// pair).
			float dL_dalpha = 0.0f;
			const int global_id = collected_id[j];
			for (int ch = 0; ch < C; ch++)
			{
				const float c = collected_colors[ch * BLOCK_SIZE + j];                                                                                       
				// Update last color (to be used in the next iteration)
				accum_rec[ch] = last_alpha * last_color[ch] + (1.f - last_alpha) * accum_rec[ch];
				last_color[ch] = c;

				const float dL_dchannel = dL_dpixel[ch];
				dL_dalpha += (c - accum_rec[ch]) * dL_dchannel;
				// Update the gradients w.r.t. color of the Gaussian. 
				// Atomic, since this pixel is just one of potentially
				// many that were affected by this Gaussian.
				atomicAdd(&(dL_dcolors[global_id * C + ch]), dchannel_dcolor * dL_dchannel);
			}
			for(int ch = 0; ch < MODAL_N; ch++)
			{
				const float c = collected_all_modals[ch * BLOCK_SIZE + j]; // modalities
				// Update last color (to be used in the next iteration)
				accum_all_modal[ch] = last_alpha * last_all_modal[ch] + (1.f - last_alpha) * accum_all_modal[ch];
				last_all_modal[ch] = c;

				const float dL_dchannel = dL_dout_all_modal[ch]; // modalities
				dL_dalpha += (c - accum_all_modal[ch]) * dL_dchannel;
				// Update the gradients w.r.t. color of the Gaussian. 
				// Atomic, since this pixel is just one of potentially
				// many that were affected by this Gaussian.
				atomicAdd(&(dL_dall_modal[global_id * MODAL_N + ch]), dchannel_dcolor * dL_dchannel); // modalities
			}
			
			dL_dalpha *= T;
			// Update last alpha (to be used in the next iteration)
			last_alpha = alpha;

			// Account for fact that alpha also influences how much of
			// the background color is added if nothing left to blend
			float bg_dot_dpixel = 0;
			for (int i = 0; i < C; i++)
				bg_dot_dpixel += bg_color[i] * dL_dpixel[i];
			dL_dalpha += (-T_final / (1.f - alpha)) * bg_dot_dpixel;


			// Helpful reusable temporary variables
			const float dL_dG = con_o.w * dL_dalpha;
			const float gdx = G * d.x;
			const float gdy = G * d.y;
			const float dG_ddelx = -gdx * con_o.x - gdy * con_o.y;
			const float dG_ddely = -gdy * con_o.z - gdx * con_o.y;

			// Update gradients w.r.t. 2D mean position of the Gaussian
			atomicAdd(&dL_dmean2D[global_id].x, dL_dG * dG_ddelx * ddelx_dx);
			atomicAdd(&dL_dmean2D[global_id].y, dL_dG * dG_ddely * ddely_dy); 

			// Update gradients w.r.t. 2D covariance (2x2 matrix, symmetric)
			atomicAdd(&dL_dconic2D[global_id].x, -0.5f * gdx * d.x * dL_dG);
			atomicAdd(&dL_dconic2D[global_id].y, -0.5f * gdx * d.y * dL_dG);
			atomicAdd(&dL_dconic2D[global_id].w, -0.5f * gdy * d.y * dL_dG);

			// Update gradients w.r.t. opacity of the Gaussian
			atomicAdd(&(dL_dopacity[global_id]), G * dL_dalpha);
		}
	}
}

// void BACKWARD::preprocess(
// 	int P, int D, int M,
// 	const float3* means3D,
// 	const int* radii,
// 	const float* shs,
// 	const bool* clamped,
// 	const glm::vec3* scales,
// 	const glm::vec4* rotations,
// 	const float scale_modifier,
// 	const float* cov3Ds,
// 	const float* viewmatrix,
// 	const float* projmatrix,
// 	const float focal_x, float focal_y,
// 	const float tan_fovx, float tan_fovy,
// 	const glm::vec3* campos,
// 	const float3* dL_dmean2D,
// 	const float* dL_dconic,
// 	glm::vec3* dL_dmean3D,
// 	float* dL_dcolor,
// 	float* dL_dcov3D,
// 	float* dL_dsh,
// 	glm::vec3* dL_dscale,
// 	glm::vec4* dL_drot)
// {
// 	// Propagate gradients for the path of 2D conic matrix computation. 
// 	// Somewhat long, thus it is its own kernel rather than being part of 
// 	// "preprocess". When done, loss gradient w.r.t. 3D means has been
// 	// modified and gradient w.r.t. 3D covariance matrix has been computed.	
// 	computeCov2DCUDA << <(P + 255) / 256, 256 >> > (
// 		P,
// 		means3D,
// 		radii,
// 		cov3Ds,
// 		focal_x,
// 		focal_y,
// 		tan_fovx,
// 		tan_fovy,
// 		viewmatrix,
// 		dL_dconic,
// 		(float3*)dL_dmean3D,
// 		dL_dcov3D);

// 	// Propagate gradients for remaining steps: finish 3D mean gradients,
// 	// propagate color gradients to SH (if desireD), propagate 3D covariance
// 	// matrix gradients to scale and rotation.
// 	preprocessCUDA<NUM_CHANNELS> << < (P + 255) / 256, 256 >> > (
// 		P, D, M,
// 		(float3*)means3D,
// 		radii,
// 		shs,
// 		clamped,
// 		(glm::vec3*)scales,
// 		(glm::vec4*)rotations,
// 		scale_modifier,
// 		projmatrix,
// 		campos,
// 		(float3*)dL_dmean2D,
// 		(glm::vec3*)dL_dmean3D,
// 		dL_dcolor,
// 		dL_dcov3D,
// 		dL_dsh,
// 		dL_dscale,
// 		dL_drot);
// }

void BACKWARD::preprocessspherical(
	int P, int D, int M,
	const float3* means3D,
	const int* radii,
	const float* shs,
	const bool* clamped,
	const glm::vec3* scales,
	const glm::vec4* rotations,
	const float scale_modifier,
	const float* cov3Ds,
	const float* viewmatrix,
	const float* projmatrix,
	const float focal_x, float focal_y,
	const float tan_fovx, float tan_fovy,
	const glm::vec3* campos,
	const int W,  int H, // add Height and Width
	const float3* dL_dmean2D,
	const float* dL_dconic,
	glm::vec3* dL_dmean3D,
	float* dL_dcolor,
	float* dL_dcov3D,
	float* dL_dsh,
	glm::vec3* dL_dscale,
	glm::vec4* dL_drot)
{
	// Propagate gradients for the path of 2D conic matrix computation. 
	// Somewhat long, thus it is its own kernel rather than being part of 
	// "preprocess". When done, loss gradient w.r.t. 3D means has been
	// modified and gradient w.r.t. 3D covariance matrix has been computed.	
	computesphericalCov2DCUDA << <(P + 255) / 256, 256 >> > (
		P,
		means3D,
		radii,
		cov3Ds,
		focal_x,
		focal_y,
		viewmatrix,
		dL_dconic,
		(float3*)dL_dmean3D,
		dL_dcov3D,
		H, //add Height and Width
		W
		);

	// Propagate gradients for remaining steps: finish 3D mean gradients,
	// propagate color gradients to SH (if desireD), propagate 3D covariance
	// matrix gradients to scale and rotation.
	preprocesssphericalCUDA<NUM_CHANNELS> << < (P + 255) / 256, 256 >> > (
		P, D, M,
		(float3*)means3D,
		radii,
		shs,
		clamped,
		(glm::vec3*)scales,
		(glm::vec4*)rotations,
		scale_modifier,
		viewmatrix,
		projmatrix,
		campos,
		(float3*)dL_dmean2D,
		(glm::vec3*)dL_dmean3D,
		dL_dcolor,
		dL_dcov3D,
		dL_dsh,
		dL_dscale,
		dL_drot,
		dL_dconic, // Add for OmniGS
		H, // Add for OmniGS
		W // Add for OmniGS
		);
}

void BACKWARD::render(
	const dim3 grid, const dim3 block,
	const uint2* ranges,
	const uint32_t* point_list,
	int W, int H,
	const float* bg_color,
	const float2* means2D,
	const float4* conic_opacity,
	const float* colors,
	const float* all_modals, // modalities
	const float* all_modal_pixels, // modalities
	const float* final_Ts,
	const uint32_t* n_contrib,
	const float* dL_dpixels,
	const float* dL_dout_all_modal, // modalities
	const float* dL_dout_plane_depths, // modalities
	float3* dL_dmean2D,
	float4* dL_dconic2D,
	float* dL_dopacity,
	float* dL_dcolors,
	float* dL_dall_modal) // modalities
{
	renderCUDA<NUM_CHANNELS, NUM_ALL_MODAL> << <grid, block >> >(
		ranges,
		point_list,
		W, H,
		bg_color,
		means2D,
		conic_opacity,
		colors,
		all_modals, // modalities
		all_modal_pixels, // modalities
		final_Ts,
		n_contrib,
		dL_dpixels,
		dL_dout_all_modal, // modalities
		dL_dout_plane_depths, // modalities
		dL_dmean2D,
		dL_dconic2D,
		dL_dopacity,
		dL_dcolors,
		dL_dall_modal // modalities
		);
}