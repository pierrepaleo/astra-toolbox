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

#ifndef _CUDA_TV_H
#define _CUDA_TV_H

#include "util.h"
#include "algo.h"

namespace astraCUDA {

class _AstraExport TV : public ReconAlgo {
public:
	TV();
	~TV();

	virtual bool init();

	// Set min/max masks to existing GPU memory buffers
	bool setMinMaxMasks(float* D_minMaskData, float* D_maxMaskData,
	                    unsigned int pitch);

	// Set min/max masks from RAM buffers
	bool uploadMinMaxMasks(const float* minMaskData, const float* maxMaskData,
	                       unsigned int pitch);


	void setRegularization(float r) { fRegularization = r; }

	virtual bool iterate(unsigned int iterations);

	// TODO: declare additional methods here

	virtual float computeDiffNorm();
	bool projLinf(float* D_gradData, float* D_data, unsigned int pitch, float radius);
	bool gradientOperator(float* D_gradData, float* D_data, unsigned int pitch, float alpha, int doUpdate);
	bool divergenceOperator(float* D_data, float* D_gradData, unsigned int pitch, float alpha, int doUpdate);
	bool signOperator(float* D_dst, float* D_src, unsigned int pitch, int nz);
	float computeOperatorNorm();

protected:
	void reset();

	// Slice-like buffers
	float* D_projData;
	float* D_x;
	float* D_xTilde;
	float* D_xold;
	float* D_sliceTmp;
	float* D_gradTmp; //
	float* D_gradTmp2; //
	unsigned int projPitch;
	unsigned int xPitch;
	unsigned int xtildePitch;
	unsigned int xoldPitch;
	unsigned int tmpPitch;
	unsigned int gradTmpPitch;
	unsigned int gradTmp2Pitch;

	// Slice gradient-like buffers
	float* D_dualp;
	unsigned int dualpPitch;

	// Sinogram-like buffers
	float* D_dualq;
	float* D_sinoTmp;
	unsigned int dualqPitch;
	unsigned int sinoTmpPitch;

	// Masks
	bool freeMinMaxMasks;
	float* D_minMaskData;
	unsigned int minMaskPitch;
	float* D_maxMaskData;
	unsigned int maxMaskPitch;

	float fRegularization;
	// Algorithm-related parameters
	int nIterComputeNorm;
	float normFactor;
};

bool doTV(float* D_volumeData, unsigned int volumePitch,
            float* D_projData, unsigned int projPitch,
            float* D_maskData, unsigned int maskPitch,
            const SDimensions& dims, const float* angles,
            const float* TOffsets, unsigned int iterations);

}

#endif