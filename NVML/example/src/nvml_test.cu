#include <iostream>
#include <cstdio>

#ifdef USE_NVML
#include <nvml.h>
#define NVML_CALL( call )				\
{										\
	nvmlReturn_t nvmlError = call;		\
	if (NVML_SUCCESS != nvmlError )	{	\
		fprintf (stderr, "NVML_ERROR: %s (%d) in %d line of %s\n", nvmlErrorString( nvmlError ), nvmlError , __LINE__, __FILE__ ); \
	}									\
}
#else
#define NVML_CALL( call )
#endif

/**
 * getNvmlDevice determines the NVML Device Id of the currently active CUDA device
 *
 * @param[out]  nvmlDeviceId    the NVML Device Id of the currently active CUDA device
 * @return                      NVML_SUCCESS in case of success. Error code of NVML API
 *                              or NVML_ERROR_UNKNOWN if CUDA Runtime API failed otherwise
 */
inline nvmlReturn_t getNvmlDevice( nvmlDevice_t* nvmlDeviceId )
{
	int activeCUDAdevice = 0;
	cudaError_t cudaError = cudaGetDevice ( &activeCUDAdevice );
	if ( cudaSuccess  != cudaError )
		return NVML_ERROR_UNKNOWN;
	
	cudaDeviceProp activeCUDAdeviceProp;
	cudaError = cudaGetDeviceProperties ( &activeCUDAdeviceProp, activeCUDAdevice );
	if ( cudaSuccess  != cudaError )
		return NVML_ERROR_UNKNOWN;
	
	unsigned int nvmlDeviceCount = 0;
	nvmlReturn_t nvmlError = nvmlDeviceGetCount ( &nvmlDeviceCount );
	if ( NVML_SUCCESS != nvmlError )
		return nvmlError;
	
	for ( unsigned int nvmlDeviceIdx = 0; nvmlDeviceIdx < nvmlDeviceCount; ++nvmlDeviceIdx )
	{
		nvmlError = nvmlDeviceGetHandleByIndex ( nvmlDeviceIdx, nvmlDeviceId );
		if ( NVML_SUCCESS != nvmlError )
			return nvmlError; 
		nvmlPciInfo_t nvmPCIInfo;
		nvmlError = nvmlDeviceGetPciInfo ( *nvmlDeviceId, &nvmPCIInfo );
		if ( NVML_SUCCESS != nvmlError )
			return nvmlError;
		//TODO: Is it sufficient to check the below? What about multi GPU boards?
		//      Do we need to consider MultiGpuBoard, multiGpuBoardGroupID of cudaDeviceProp?
		if ( static_cast<unsigned int>(activeCUDAdeviceProp.pciBusID) == nvmPCIInfo.bus &&
		     static_cast<unsigned int>(activeCUDAdeviceProp.pciDeviceID) == nvmPCIInfo.device &&
			 static_cast<unsigned int>(activeCUDAdeviceProp.pciDomainID) == nvmPCIInfo.domain )
			break;
	}
	return NVML_SUCCESS;
}

inline nvmlReturn_t reportApplicationClocks( nvmlDevice_t nvmlDeviceId )
{
	unsigned int appSMclock = 0;
	unsigned int appMemclock = 0;
	nvmlReturn_t nvmlError = nvmlDeviceGetApplicationsClock ( nvmlDeviceId, NVML_CLOCK_SM, &appSMclock );
	if ( NVML_SUCCESS != nvmlError )
			return nvmlError;
	nvmlError = nvmlDeviceGetApplicationsClock ( nvmlDeviceId, NVML_CLOCK_MEM, &appMemclock );
	if ( NVML_SUCCESS != nvmlError )
			return nvmlError;
	
	std::cout<<"Application Clocks = ("<<appMemclock<<","<<appSMclock<<")"<<std::endl;
	return NVML_SUCCESS;
}

__global__ void test_kernel()
{
	printf("test_kernel()\n");
}

int matrixMultiply(dim3 &dimsA, dim3 &dimsB);

int main()
{
	cudaSetDevice(0);
	test_kernel<<<1,1>>>();
	cudaDeviceSynchronize();
	
	NVML_CALL( nvmlInit() );
	
	nvmlDevice_t nvmlDeviceId;
	NVML_CALL( getNvmlDevice( &nvmlDeviceId ) );
	
	NVML_CALL( reportApplicationClocks( nvmlDeviceId ) );
	
	unsigned int memClock = 0;
	NVML_CALL( nvmlDeviceGetClockInfo( nvmlDeviceId, NVML_CLOCK_MEM, &memClock ) );
	
	unsigned int numSupportedSMClocks = 32;
	unsigned int smClocksMHz[32];
	NVML_CALL( nvmlDeviceGetSupportedGraphicsClocks ( nvmlDeviceId, memClock, &numSupportedSMClocks, smClocksMHz ) );
	
	unsigned int numSupportedMemClocks = 32;
	unsigned int memClocksMHz[32];
	NVML_CALL( nvmlDeviceGetSupportedMemoryClocks ( nvmlDeviceId, &numSupportedMemClocks, memClocksMHz ) ); 

	unsigned int maxSMclock = 0;
	unsigned int maxMemclock = 0;
	NVML_CALL( nvmlDeviceGetMaxClockInfo ( nvmlDeviceId, NVML_CLOCK_SM, &maxSMclock ) );
	NVML_CALL( nvmlDeviceGetMaxClockInfo ( nvmlDeviceId, NVML_CLOCK_MEM, &maxMemclock ) );

	//Check permissions to modify application clocks
	nvmlEnableState_t isRestricted;
	NVML_CALL( nvmlDeviceGetAPIRestriction ( nvmlDeviceId, NVML_RESTRICTED_API_SET_APPLICATION_CLOCKS, &isRestricted ) );
	
	if ( NVML_FEATURE_DISABLED == isRestricted )
	{
		dim3 dimsA(256,256);
		dim3 dimsB(256,256);
		std::cout<<"Setting application SM clocks min value."<<std::endl;
		NVML_CALL( nvmlDeviceSetApplicationsClocks ( nvmlDeviceId, memClocksMHz[0], smClocksMHz[numSupportedSMClocks-1] ) );

		NVML_CALL( reportApplicationClocks( nvmlDeviceId ) );
		
		//Is this safe?
		matrixMultiply(dimsA, dimsB);

		std::cout<<"Setting application clocks max value."<<std::endl;
		NVML_CALL( nvmlDeviceSetApplicationsClocks ( nvmlDeviceId, maxMemclock, maxSMclock ) );
		
		NVML_CALL( reportApplicationClocks( nvmlDeviceId ) );
		matrixMultiply(dimsA, dimsB);
	}
	
	//Reset Application Clocks and Shutdown NVML
	if ( NVML_FEATURE_DISABLED == isRestricted )
	{
		NVML_CALL( nvmlDeviceResetApplicationsClocks ( nvmlDeviceId ) ); 
	}
	NVML_CALL( nvmlShutdown() );
	
	cudaDeviceReset();
	return 0;
}
