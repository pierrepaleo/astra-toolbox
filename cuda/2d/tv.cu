/*
-----------------------------------------------------------------------
Copyright: 2010-2015, iMinds-Vision Lab, University of Antwerp
           2014-2015, CWI, Amsterdam

Contact: astra@uantwerpen.be
Website: http://sf.net/projects/astra-toolbox

This file is part of the ASTRA Toolbox.


The ASTRA Toolbox is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

The ASTRA Toolbox is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with the ASTRA Toolbox. If not, see <http://www.gnu.org/licenses/>.

-----------------------------------------------------------------------
$Id$
*/

#include <cstdio>
#include <cassert>

#include "tv.h"
#include "util.h"
#include "arith.h"

#ifdef STANDALONE
#include "testutil.h"
#endif

namespace astraCUDA {


// optimization parameters
static const unsigned int threadsPerBlock = 16;


static int iDivUp(int a, int b){
	return (a % b != 0) ? (a / b + 1) : (a / b);
}


TV::TV() : ReconAlgo()
{
	D_projData = 0;
	//~ D_x = 0;
	D_xTilde = 0;
	D_xold = 0;
	D_sliceTmp = 0;
	D_dualp = 0;
	D_dualq = 0;
	D_sinoTmp = 0;
	D_gradTmp = 0; //
	D_gradTmp2 = 0; //

	D_minMaskData = 0;
	D_maxMaskData = 0;

	normFactor = 1.2;
	fRegularization = 1.0f;
	freeMinMaxMasks = false;
}


TV::~TV()
{
	reset();
}

void TV::reset()
{
	cudaFree(D_projData);
	//~ cudaFree(D_x);
	cudaFree(D_xTilde);
	cudaFree(D_xold);
	cudaFree(D_sliceTmp);
	cudaFree(D_dualp);
	cudaFree(D_dualq);
	cudaFree(D_sinoTmp);
	cudaFree(D_gradTmp); //
	cudaFree(D_gradTmp2); //

	if (freeMinMaxMasks) {
		cudaFree(D_minMaskData);
		cudaFree(D_maxMaskData);
	}

	D_projData = 0;
	//~ D_x = 0;
	D_xTilde = 0;
	D_xold = 0;
	D_sliceTmp = 0;
	D_dualp = 0;
	D_dualq = 0;
	D_sinoTmp = 0;
	D_minMaskData = 0;
	D_maxMaskData = 0;
	D_gradTmp = 0; //
	D_gradTmp2 = 0; //


	freeMinMaxMasks = false;
	useVolumeMask = false;
	useSinogramMask = false;
	fRegularization = 1.0f;

	ReconAlgo::reset();
}

bool TV::init()
{

    allocateProjectionData(D_projData, projPitch, dims);
	zeroProjectionData(D_projData, projPitch, dims);

    allocateVolumeData(D_x, xPitch, dims);
	zeroVolumeData(D_x, xPitch, dims);

    allocateVolumeData(D_xold, xoldPitch, dims);
	zeroVolumeData(D_xold, xoldPitch, dims);

    allocateVolumeData(D_sliceTmp, tmpPitch, dims);
	zeroVolumeData(D_sliceTmp, tmpPitch, dims);

    allocateVolumeData(D_xTilde, xtildePitch, dims);
	zeroVolumeData(D_xTilde, xtildePitch, dims);

	allocateProjectionData(D_sinoTmp, sinoTmpPitch, dims);
	zeroProjectionData(D_sinoTmp, sinoTmpPitch, dims);

	allocateProjectionData(D_dualq, dualqPitch, dims);
	zeroProjectionData(D_dualq, dualqPitch, dims);

	// if float2 cannot be used, we use a buffer with height*2
    SDimensions dimsGrad = dims;
    dimsGrad.iVolHeight *= 2;
    allocateVolumeData(D_dualp, dualpPitch, dimsGrad);
	zeroVolumeData(D_dualp, dualpPitch, dimsGrad);
   	// if not cublas
   	allocateVolumeData(D_gradTmp, gradTmpPitch, dimsGrad);
	zeroVolumeData(D_gradTmp, gradTmpPitch, dimsGrad);
	allocateVolumeData(D_gradTmp2, gradTmp2Pitch, dimsGrad);
	zeroVolumeData(D_gradTmp2, gradTmp2Pitch, dimsGrad);

    nIterComputeNorm = 20;
    normFactor = 1.2f;

	// TODO: check if allocations succeeded
	return true;
}


bool TV::setMinMaxMasks(float* D_minMaskData_, float* D_maxMaskData_,
	                      unsigned int iPitch)
{
	D_minMaskData = D_minMaskData_;
	D_maxMaskData = D_maxMaskData_;
	minMaskPitch = iPitch;
	maxMaskPitch = iPitch;

	freeMinMaxMasks = false;
	return true;
}

bool TV::uploadMinMaxMasks(const float* pfMinMaskData, const float* pfMaxMaskData,
	                         unsigned int iPitch)
{
	freeMinMaxMasks = true;
	bool ok = true;
	if (pfMinMaskData) {
		allocateVolumeData(D_minMaskData, minMaskPitch, dims);
		ok = copyVolumeToDevice(pfMinMaskData, iPitch,
		                        dims,
		                        D_minMaskData, minMaskPitch);
	}
	if (!ok)
		return false;

	if (pfMaxMaskData) {
		allocateVolumeData(D_maxMaskData, maxMaskPitch, dims);
		ok = copyVolumeToDevice(pfMaxMaskData, iPitch,
		                        dims,
		                        D_maxMaskData, maxMaskPitch);
	}
	if (!ok)
		return false;

	return true;
}





__global__ void projLinfKernel(float* dst, float* src, const SDimensions dims, unsigned int pitch, float radius) {
	unsigned int gidx = threadIdx.x + blockIdx.x*blockDim.x;
	unsigned int gidy = threadIdx.y + blockIdx.y*blockDim.y;
    unsigned int sizeX = dims.iVolWidth, sizeY = dims.iVolHeight;

	if (gidx < sizeX && gidy < sizeY) {
		unsigned int idx = gidy*pitch+gidx;
		float val_x = src[idx];
		float val_y = src[pitch*sizeY + idx];

		dst[idx] = copysignf(min(fabsf(val_x), radius), val_x);
		dst[pitch*sizeY + idx] = copysignf(min(fabsf(val_y), radius), val_y);
	}
}

bool TV::projLinf(float* D_gradData, float* D_data, unsigned int pitch, float radius) {
	dim3 nBlocks, nThreadsPerBlock;
	nThreadsPerBlock = dim3(threadsPerBlock, threadsPerBlock, 1);
	nBlocks = dim3(iDivUp(dims.iVolWidth, threadsPerBlock), iDivUp(dims.iVolHeight, threadsPerBlock), 1);

	projLinfKernel<<<nBlocks, nThreadsPerBlock>>>(D_data, D_gradData, dims, pitch, radius);
	return true;
}



__global__ void gradientKernel2D(float* dst, float* src, const SDimensions dims, unsigned int pitch, float alpha, int doUpdate) {
    unsigned int gidx = threadIdx.x + blockIdx.x*blockDim.x;
    unsigned int gidy = threadIdx.y + blockIdx.y*blockDim.y;
    unsigned int sizeX = dims.iVolWidth, sizeY = dims.iVolHeight;
    float val_x = 0, val_y = 0;

    if (gidx < sizeX && gidy < sizeY) {
        if (gidx == sizeX-1) val_y = 0;
        else val_y = src[(gidy)*pitch+gidx+1] - src[gidy*pitch+gidx];
        if (gidy == sizeY-1) val_x = 0;
        else val_x = src[(gidy+1)*pitch+gidx] - src[gidy*pitch+gidx];

        if (doUpdate) {
            val_x = alpha*val_x + dst[gidy*pitch+gidx];
            val_y = alpha*val_y + dst[pitch*sizeY + gidy*pitch+gidx];
        }

        dst[(gidy)*pitch+gidx] = val_x;
        dst[pitch*sizeY + (gidy)*pitch+gidx] = val_y;
    }
}


// gradientOperator(dst, src, alpha, 0)  computes  dst = gradient(src)
// gradientOperator(dst, src, alpha, 1)  computes  dst = dst + alpha*gradient(src)
bool TV::gradientOperator(float* D_gradData, float* D_data, unsigned int pitch, float alpha, int doUpdate) {
    dim3 nBlocks, nThreadsPerBlock;
    nThreadsPerBlock = dim3(threadsPerBlock, threadsPerBlock, 1);
    nBlocks = dim3(iDivUp(dims.iVolWidth, threadsPerBlock), iDivUp(dims.iVolHeight, threadsPerBlock), 1);

    gradientKernel2D<<<nBlocks, nThreadsPerBlock>>>(D_gradData, D_data, dims, pitch, alpha, doUpdate);
    return true;
}


__global__ void divergenceKernel2D(float* dst, float* src, const SDimensions dims, unsigned int pitch, float alpha, int doUpdate) {
    unsigned int gidx = threadIdx.x + blockIdx.x*blockDim.x;
    unsigned int gidy = threadIdx.y + blockIdx.y*blockDim.y;
    unsigned int sizeX = dims.iVolWidth, sizeY = dims.iVolHeight;
    float val_x = 0, val_y = 0;

    if (gidx < sizeX && gidy < sizeY) {
        if (gidx == 0) val_y = src[(gidy)*pitch+gidx];
        else val_y = src[pitch*sizeY + (gidy)*pitch+gidx] - src[pitch*sizeY +  (gidy)*pitch+gidx-1];
        if (gidy == 0) val_x = src[(gidy)*pitch+gidx];
        else val_x = src[(gidy)*pitch+gidx] - src[(gidy-1)*pitch+gidx];

        if (doUpdate) dst[(gidy)*pitch+gidx] += alpha*(val_x + val_y);
        else dst[(gidy)*pitch+gidx] = val_x + val_y;
    }
}


// divergenceOperator(dst, src, alpha, 0)  computes  dst = div(src)
// divergenceOperator(dst, src, alpha, 1)  computes  dst = dst + alpha*div(src)
bool TV::divergenceOperator(float* D_data, float* D_gradData, unsigned int pitch, float alpha, int doUpdate) {
    dim3 nBlocks, nThreadsPerBlock;
    nThreadsPerBlock = dim3(threadsPerBlock, threadsPerBlock, 1);
    nBlocks = dim3(iDivUp(dims.iVolWidth, threadsPerBlock), iDivUp(dims.iVolHeight, threadsPerBlock), 1);

    divergenceKernel2D<<<nBlocks, nThreadsPerBlock>>>(D_data, D_gradData, dims, pitch, alpha, doUpdate);
    return true;
}


__global__ void signKernel2D(float* dst, float* src, const SDimensions dims, unsigned int pitch, int nz) {
    unsigned int gidx = threadIdx.x + blockIdx.x*blockDim.x;
    unsigned int gidy = threadIdx.y + blockIdx.y*blockDim.y;
    unsigned int sizeX = dims.iVolWidth, sizeY = dims.iVolHeight;
    unsigned int idx = gidy*pitch + gidx;
    if (gidx < sizeX && gidy < sizeY) {
		dst[idx] = copysignf(1, src[idx]);
		if (nz > 1) for (int i = 1; i < nz; i++) {
			dst[i*pitch*sizeY + idx] = copysignf(1, src[i*pitch*sizeY + idx]);
		}
	}
}

// signOperator(dst, src, 1) computes dst = sign(src).
// If the last parameter is greater than 1, it means that there are several buffers
bool TV::signOperator(float* D_dst, float* D_src, unsigned int pitch, int nz) {
    dim3 nBlocks, nThreadsPerBlock;
    nThreadsPerBlock = dim3(threadsPerBlock, threadsPerBlock, 1);
    nBlocks = dim3(iDivUp(dims.iVolWidth, threadsPerBlock), iDivUp(dims.iVolHeight, threadsPerBlock), 1);

    signKernel2D<<<nBlocks, nThreadsPerBlock>>>(D_dst, D_src, dims, pitch, nz);
    return true;
}









// Compute the norm of the operator K = [grad, P]
// using ||K|| = sqrt(max_eigen(K^T * K))
float TV::computeOperatorNorm() {
    float norm = -1.0f;

    zeroVolumeData(D_sliceTmp, tmpPitch, dims);
    callBP(D_sliceTmp, tmpPitch, D_sinoData, sinoPitch, 1.0f);

    // power method for computing max eigenval of P^T P
    for (unsigned int iter = 0 ; iter < nIterComputeNorm; ++iter) {
        // x := P^T(P(x)) - div(grad(x))
        zeroProjectionData(D_sinoTmp, sinoTmpPitch, dims);
        callFP(D_sliceTmp, tmpPitch, D_sinoTmp, sinoTmpPitch, 1.0f);
        zeroVolumeData(D_sliceTmp, tmpPitch, dims);
        callBP(D_sliceTmp, tmpPitch, D_sinoTmp, sinoTmpPitch, 1.0f);
        gradientOperator(D_dualp, D_sliceTmp, tmpPitch, 1.0, 0);
        divergenceOperator(D_sliceTmp, D_dualp, tmpPitch, -1.0f, 1); // TODO: what is computed is div or -div ? In the latter case: put alpha=+1

        // Compute norm and scale x
        norm = dotProduct2D(D_sliceTmp, tmpPitch, dims.iVolWidth, dims.iVolHeight); // TODO: check
        norm = sqrt(norm);
        processVol<opMul>(D_sliceTmp, 1.0f/norm, tmpPitch, dims);
    }
    //
    cudaMemset(D_dualp, 0, 2*dims.iVolHeight*tmpPitch*sizeof(float));
    //
    if (norm < 0) return -1.0f;     // something went wrong
    else return sqrt(norm);
}




/// DEBUG -------------------------

void write_device_array(float* data, int nels, char* fname) {

	float* hdata = (float*) calloc(nels, sizeof(float));
	cudaMemcpy(hdata, data, nels*sizeof(float), cudaMemcpyDeviceToHost);

	FILE* fid = fopen(fname, "wb");
	fwrite(hdata, sizeof(float), nels, fid);
	fclose(fid);

	free(hdata);

}

/// ----------------------------


// TODO: implement volume mask
// TODO: implement either use_fbp in iterations, or preconditioned CP
// TODO: use less buffers (for eg use D_x = D_volumeData ?)
bool TV::iterate(unsigned int iterations)
{
    // Compute the primal and dual steps, for non-preconditionned CP
    float L = computeOperatorNorm();  //TODO: abort if norm is negative
    float sigma = 1.0f/L;       	  // dual step
    float tau = 1.0f/L;         	  // primal step
    float theta = 1.;				  // C-P relaxation parameter

	printf("L = %f, sigma = %f\n", L, sigma);
	fRegularization = 10.0; /// DEBUG
	printf("Lambda = %f\n", fRegularization);

	// iteration
	for (unsigned int iter = 0; iter < iterations; ++iter) {

		printf("Iteration %d\n", iter); /// DEBUG

		// Update dual variables
		// ----------------------
		// p = proj_linf(p + sigma*gradient(x_tilde), Lambda)
		/// DEBUG
		/// write_device_array(D_dualp, dims.iVolHeight*dims.iVolWidth, "p0.dat"); /// DEBUG
		/// write_device_array(D_dualp, dims.iVolHeight*dims.iVolWidth, "p1.dat"); /// DEBUG
		/// -----
		gradientOperator(D_dualp, D_xTilde, dualpPitch, sigma, 1);

		projLinf(D_dualp, D_dualp, dualpPitch, fRegularization); // *sigma


		// q = (q + sigma*P(x_tilde) - sigma*data)/(1.0 + sigma)
        callFP(D_xTilde, xtildePitch, D_dualq, dualqPitch, sigma);          // q = q + sigma*P(xtilde)
        processSino<opAddScaled>(D_dualq, D_sinoData, -sigma, 				// q -= sigma*data
								 dualqPitch, dims);
        processSino<opMul>(D_dualq, 1.0f/(1.0f+sigma), dualqPitch, dims);   // q /= 1+sigma
        /// DEBUG
		/// write_device_array(D_dualq, dims.iProjDets*dims.iProjAngles, "sino_a.dat"); /// DEBUG
		/// -----


		// Update primal variables
		// ------------------------
		duplicateVolumeData(D_xold, D_x, volumePitch, dims);
		// x = x + tau*div(p) - tau*P^T(q)
		divergenceOperator(D_x, D_dualp, xPitch, tau, 1);					// x = x + tau*div(p)
		callBP(D_x, xPitch, D_dualq, dualqPitch, -tau);		  				// x += (-tau)*P^T(q)

        // Extra constraints (if any)
        // --------------------------
		if (useMinConstraint)
			processVol<opClampMin>(D_x, fMinConstraint, xPitch, dims);
		if (useMaxConstraint)
			processVol<opClampMax>(D_x, fMaxConstraint, xPitch, dims);
		if (D_minMaskData)
			processVol<opClampMinMask>(D_x, D_minMaskData, xPitch, dims);
		if (D_maxMaskData)
			processVol<opClampMaxMask>(D_x, D_maxMaskData, xPitch, dims);

        // Update step
        // ------------
        // x_tilde = x + theta*(x - x_old) = (1+theta)*x - theta*x_old
        duplicateVolumeData(D_xTilde, D_x, xtildePitch, dims);
        processVol<opMul>(D_xTilde, 1.0f+theta, xtildePitch, dims);
        processVol<opAddScaled>(D_xTilde, D_xold, -theta, xtildePitch, dims);
        // TODO: this in two steps ?

	}

	 duplicateVolumeData(D_volumeData, D_x, volumePitch, dims);

	return true;
}

/// Compute  0.5 * ||P(x) - data||_2^2  + Lambda*TV(x)
float TV::computeDiffNorm()
{
	// copy sinogram to projection data
	duplicateProjectionData(D_projData, D_sinoData, projPitch, dims);

	// do FP, subtracting projection from sinogram
	callFP(D_volumeData, volumePitch, D_projData, projPitch, -1.0f);

	// compute norm of D_projData
	float l2 = dotProduct2D(D_projData, projPitch, dims.iProjDets, dims.iProjAngles);
	l2 *= 0.5;

	// cublasSasum() would be ideal. If it cannot be used,
	// the only solution is to use a dot product between grad(x) and sign(grad(x)),
	// but it entails two extra gradient buffers
	gradientOperator(D_gradTmp, D_volumeData, gradTmpPitch, 0, 0);
	signOperator(D_gradTmp2, D_gradTmp, gradTmpPitch, 2);
	float l1 = dotProduct2D(D_gradTmp, gradTmpPitch, dims.iVolWidth, dims.iVolHeight);

	return l2 + fRegularization*l1;
}


bool doTV(float* D_volumeData, unsigned int volumePitch,
            float* D_sinoData, unsigned int sinoPitch,
            float* D_maskData, unsigned int maskPitch,
            const SDimensions& dims, const float* angles,
            const float* TOffsets, unsigned int iterations)
{
	TV tv;
	bool ok = true;

	ok &= tv.setGeometry(dims, angles);
	if (D_maskData)
		ok &= tv.enableVolumeMask();
	if (TOffsets)
		ok &= tv.setTOffsets(TOffsets);

	if (!ok)
		return false;

	ok = tv.init();
	if (!ok)
		return false;

	if (D_maskData)
		ok &= tv.setVolumeMask(D_maskData, maskPitch);

	ok &= tv.setBuffers(D_volumeData, volumePitch, D_sinoData, sinoPitch);
	if (!ok)
		return false;

	ok = tv.iterate(iterations);

	return ok;
}

}

#ifdef STANDALONE

using namespace astraCUDA;

int main()
{
	float* D_volumeData;
	float* D_sinoData;

	SDimensions dims;
	dims.iVolWidth = 1024;
	dims.iVolHeight = 1024;
	dims.iProjAngles = 512;
	dims.iProjDets = 1536;
	dims.fDetScale = 1.0f;
	dims.iRaysPerDet = 1;
	unsigned int volumePitch, sinoPitch;

	allocateVolume(D_volumeData, dims.iVolWidth, dims.iVolHeight, volumePitch);
	zeroVolume(D_volumeData, volumePitch, dims.iVolWidth, dims.iVolHeight);
	printf("pitch: %u\n", volumePitch);

	allocateVolume(D_sinoData, dims.iProjDets, dims.iProjAngles, sinoPitch);
	zeroVolume(D_sinoData, sinoPitch, dims.iProjDets, dims.iProjAngles);
	printf("pitch: %u\n", sinoPitch);

	unsigned int y, x;
	float* sino = loadImage("sino.png", y, x);

	float* img = new float[dims.iVolWidth*dims.iVolHeight];

	copySinogramToDevice(sino, dims.iProjDets, dims.iProjDets, dims.iProjAngles, D_sinoData, sinoPitch);

	float* angle = new float[dims.iProjAngles];

	for (unsigned int i = 0; i < dims.iProjAngles; ++i)
		angle[i] = i*(M_PI/dims.iProjAngles);

	TV tv;

	tv.setGeometry(dims, angle);
	tv.init();

	tv.setBuffers(D_volumeData, volumePitch, D_sinoData, sinoPitch);

	tv.iterate(25);


	delete[] angle;

	copyVolumeFromDevice(img, dims.iVolWidth, dims, D_volumeData, volumePitch);

	saveImage("vol.png",dims.iVolHeight,dims.iVolWidth,img);

	return 0;
}
#endif
