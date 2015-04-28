﻿//
// Permission is granted to use, copy, distribute and prepare derivative works of this
// software for any purpose and without fee, provided, that the above copyright notice
// and this statement appear in all copies.  Intel makes no representations about the
// suitability of this software for any purpose.  THIS SOFTWARE IS PROVIDED "AS IS."
// INTEL SPECIFICALLY DISCLAIMS ALL WARRANTIES, EXPRESS OR IMPLIED, AND ALL LIABILITY,
// INCLUDING CONSEQUENTIAL AND OTHER INDIRECT DAMAGES, FOR THE USE OF THIS SOFTWARE,
// INCLUDING LIABILITY FOR INFRINGEMENT OF ANY PROPRIETARY RIGHTS, AND INCLUDING THE
// WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE.  Intel does not
// assume any responsibility for any errors which may appear in this software nor any
// responsibility to update it.
//--------------------------------------------------------------------------------------

Shader "Hidden/RayMarchMetavoxel" {
Properties{
	_VolumeTexture("Metavoxel fill data", 3D) = "" {}
	_LightPropogationTexture("Light Propogation", 2D) = "" {}		
	SrcFactor ("SrcFactor", Int) = 0
	DstFactor ("DstFactor", Int) = 0
	SrcFactorA ("SrcFactorA", Int) = 0
	DstFactorA ("DstFactorA", Int) = 0
}
SubShader
{
Pass
{
Cull Front ZWrite Off ZTest Less
// Syntax: Blend SrcFactor DstFactor, SrcFactorA DstFactorA				
// Set these properties via script to avoid having two shaders that differ only in the blend modes
Blend [SrcFactor] [DstFactor], [SrcFactorA] [DstFactorA]
BlendOp Add

CGPROGRAM
#pragma target 5.0
//#pragma enable_d3d11_debug_symbols

#pragma vertex vert
#pragma fragment frag
// Following pragma can be commented out to avoid generation of various permutations of this shader
// They are purely debug options
#pragma multi_compile DBG_ON_DRAW_ORDER DBG_OFF_DRAW_ORDER
#pragma multi_compile DBG_ON_BLEND_FUNC DBG_OFF_BLEND_FUNC
#pragma multi_compile DBG_ON_NUM_SAMPLES DBG_OFF_NUM_SAMPLES

#include "UnityCG.cginc"
#define green1 float4(0.0, 0.2, 0.0, 0.5)
#define green2 float4(0.0, 0.5, 0.0, 0.5)
#define yellow float4(0.5, 0.5, 0.0, 0.5)
#define orange float4(0.6, 0.4, 0.0, 0.5)
#define red float4(0.6, 0.0, 0.0, 0.5)
#define seethrough float4(0.0, 0.0, 0.0, 0.0)
#define SQ_ROOT_3 1.73205

sampler3D _VolumeTexture;	// per-voxel data for the current metavoxel
sampler2D _CameraDepth;		// camera's depth buffer as texture

// Per Metavoxel uniforms
CBUFFER_START(MetavoxelConstants)
	float4x4 _MetavoxelToWorld;
	float4x4 _CameraToMetavoxel;	
	float3 _MetavoxelIndex;		
CBUFFER_END

// Metavoxel Grid (Volume) rendering uniforms
CBUFFER_START(VolumeConstants)
	float3 _MetavoxelGridDim;	
	float3 _MetavoxelGridCenter;
	float _MetavoxelScale;
	float _NumVoxels; // metavoxel's voxel dimensions
	int _MetavoxelBorderSize;	
	int _NumRaymarchStepsPerMV;
	int _SoftDistance;
	//float4 _AABBMin;
	//float4 _AABBMax;	
CBUFFER_END

// Camera uniforms
CBUFFER_START(CameraConstants)
	float4x4 _WorldToCamera; // set by Unity when declared
	float _Fov;
	float _NearZ, _FarZ;	
	//float4 _ScreenParams; // built-in Unity shader variable; http://docs.unity3d.com/462/Documentation/Manual/SL-BuiltinValues.html
CBUFFER_END

// Debug stuff
CBUFFER_START(TmpConstants)
	int _OrderIndex;
	int _NumMetavoxelsCovered;
	int _RayMarchBlendOver;
CBUFFER_END

struct Ray {
	float3 o; // origin
	float3 d; // direction (normalized)
};
				
			
// Simon Green's beautiful ray-box intersection code
bool
IntersectBox(Ray r, float3 boxmin, float3 boxmax, 
				out float tnear, out float tfar)
{
	// compute intersection of ray with all six bbox planes
	float3 invR = 1.0 / r.d;
	float3 tbot = invR * (boxmin.xyz - r.o);
	float3 ttop = invR * (boxmax.xyz - r.o);
	// re-order intersections to find smallest and largest on each axis
	float3 tmin = min(ttop, tbot);
	float3 tmax = max(ttop, tbot);
	// find the largest tmin and the smallest tmax
	float2 t0 = max(tmin.xx, tmin.yz);
	tnear = max(t0.x, t0.y);
	t0 = min(tmax.xx, tmax.yz);
	tfar = min(t0.x, t0.y);
	// check for hit
	bool hit;
	if ((tnear > tfar))
		hit = false;
	else
		hit = true;
	return hit;
}


// Color the metavoxels being raymarched in the order they were submitted
// [t = 0] bright green --> dull green --> bright blue --> dull blue --> bright red --> dull red [t = end]
float4 DrawOrderColoring()
{	
	int numColorsPerChannel = ceil(_NumMetavoxelsCovered / (float) 3);

	int channelSelect = _OrderIndex / numColorsPerChannel;
	int channelIndex = _OrderIndex % numColorsPerChannel;

	float channelIntensity = (numColorsPerChannel - channelIndex) / float (numColorsPerChannel);

	if (channelSelect == 0)
		return float4(0, channelIntensity, 0, 1);
	else if (channelSelect == 1)
		return float4(0, 0, channelIntensity, 1);
	else
		return float4(channelIntensity, 0, 0, 1);	
}


// Debug viewer to show number of samples marched per metavoxel
float4 RayMarchSamplesColoring(int samples)
{
	int samplesby5 = _NumRaymarchStepsPerMV/5;

	if (samples < samplesby5)
		return red;
	if (samples < 2*samplesby5)
		return orange;
	if (samples < 3*samplesby5)
		return yellow;
	if (samples < 4*samplesby5)
		return green2;
	
	return green1;						
}

struct v2f {
	float4 pos : SV_POSITION;
	float3 cameraPos : TEXCOORD;
};


// Vertex shader
v2f
vert(appdata_base i) {
	// every vertex submitted is in a unit-metavoxel space
	// transform from model -> world -> eye -> proj -> clip space
	v2f o;

	// can't use the default UNITY_MATRIX_MVP since the draw is made using Graphics.DrawMeshNow without the metavoxel scale info
	o.pos = mul(mul(UNITY_MATRIX_VP, _MetavoxelToWorld), i.vertex); // clip space
	o.cameraPos = mul( _WorldToCamera, mul(_MetavoxelToWorld, i.vertex) ); // camera space
	return o;
}
	
// Fragment shader
// Ray march the current metavoxel (against the light direction), sampling from its 3D texture and 
// blending samples back-to-front. Avoid artifacts from metavoxel-discretization of the volume by
// choosing the same number of samples per ray across the volume (step lengths will differ as a result)
half4
frag(v2f i) : COLOR
{			
	// Debug options
	#if defined(DBG_ON_DRAW_ORDER)
		return DrawOrderColoring();
	#endif

	#if defined(DBG_ON_BLEND_FUNC)
		if (_RayMarchBlendOver == 1)
			return float4(0.5, 0.5, 0, 1); // yellow for back-to-front blending
		else
			return float4(0, 0.5, 0.5, 1); // cyan for front-to-back blending
	#endif


	// Naming convention:  
	// Positions and directions are generally prefixed with their space [cs = camera (view) space, mv = metavoxel space]
	// All spaces use the LHS convention
					
	// Find ray direction from camera through this pixel
	float3 csRayDir;
	csRayDir.xy = (2.0 * i.pos.xy / _ScreenParams) - 1.0; // [0, wh] to [-1, 1];
	csRayDir.x *= (_ScreenParams.x / _ScreenParams.y); // account for aspect ratio
	
	// in DX, screen space origin is at the top. however, when rendering into a RenderTexture (in this case, using DrawMeshNow), the RT is flipped
	// vertically and so we don't need to do csRayDir.y *= -1.0; to get a LHS ray direction
	// For details, see http://docs.unity3d.com/Manual/SL-PlatformDifferences.html for differences b/w rendering to a RenderTexture and using Graphics.Blit
	csRayDir.z = rcp(tan(_Fov / 2.0)); // tan(fov_y / 2) = 1 / (norm_z)
	csRayDir = normalize(csRayDir);
			
	// alternative way to find ray direction using interpolated world pos from the VS		
	//float3 csRayDir = normalize(mul(_WorldToCameraMatrix, float4(i.worldPos - _CameraWorldPos, 0)));

	// Find the approximate bounds of the entire metavoxel grid region in camera space
	// This is done to to find the near and far AABB planes of the volume (parallel to camera view plane) to start/end the ray march through the volume
	// for the current pixel. We try to hide the discreteness of the metavoxel grid by marching through it as a single large volume.
	float3 csVolOrigin = mul(_WorldToCamera, float4(_MetavoxelGridCenter, 1));
	float2 nn = max(_MetavoxelGridDim.xx, _MetavoxelGridDim.yz);
	float maxGridDim = max(nn.x, nn.y);
	float csVolHalfZ = SQ_ROOT_3 * 0.5 * maxGridDim * _MetavoxelScale;
	float csZVolMin = csVolOrigin.z - csVolHalfZ,
		  csZVolMax = csVolOrigin.z + csVolHalfZ;
	float3 csAABBStart	= csRayDir * (csZVolMin / csRayDir.z); // start is closer to the camera; camera is at the origin in camera space
	float csRayLength = 2 * csVolHalfZ;

	// Since we're raymarching only one metavoxel in the fragment shader and sampling from it's 3D texture, it's convenient to
	// do it in metavoxel (mv) space
	Ray mvRay;
	mvRay.o = mul(_CameraToMetavoxel, float4(csAABBStart, 1));
	mvRay.d = normalize( mul(_CameraToMetavoxel, float4(csRayDir, 0)) );
	 
	// The number of steps marched along any ray from the camera is a constant. The step length varies as a result (oblique rays == longer steps)
	float totalRayMarchSteps = /*SQ_ROOT_3*/ maxGridDim * float(_NumRaymarchStepsPerMV); // per ray
	float oneOverTotalRayMarchSteps = rcp(totalRayMarchSteps);
	float mvRayLength = csRayLength * rcp(_MetavoxelScale); // [todo] this restricts metavoxel to only cubes
	float mvStepSize = mvRayLength * oneOverTotalRayMarchSteps;

	// Find the intersection between the ray and the current metavoxel	
	float3 mvMin = float3(-0.5, -0.5, -0.5);				
	float t1, t2; // t1 and t2 represent distance from the ray origin (near plane of the volume AABB) of the intersection points on the metavoxel (t1, t2 >= 0)
	bool intersects = IntersectBox(mvRay, mvMin, -mvMin, t1, t2);
	if (!intersects)
		return seethrough; // ray passes through the cube corner
	
	// if the exit point of the metavoxel (that passed the depth test) is really close to an object, make it soft
	bool exitNearObject = false;

	// convert depth buffer non-linear z to view space Z
	float dScene = tex2D(_CameraDepth, 1 - i.pos.xy/_ScreenParams).r; // Depth texture is flipped in both X and Y

	float a = _FarZ * rcp(_FarZ - _NearZ), b = -_NearZ * a;	// perspective projection third row (column major) is [0  0  f/f-n  -fn/(f-n)]
	//
	//Cz = Vz * a  +  b
	//Cw = Vz
	//d = Cz/Cw
	//d = a + b/Vz
	float dMetavoxelExit = a + b * rcp(i.cameraPos.z);	

	//Vz = b / (d - a)
	float csSceneDepth = b * rcp(dScene - a);
	float csMetavoxelExitZ = i.cameraPos.z;
	float epsilon = 0.0;

	if (dScene < dMetavoxelExit)
	//if (csSceneDepth < csMetavoxelExitZ)
		return float4(dScene, 0,0,0.6);
		//exitNearObject = true;

	// find step indices; note that tentry and texit are guaranteed to be >=0
	// however, it is possible for the camera to be within the current metavoxel, in which case texit > tcamera >= tentry. 
	// for this case, we should ensure we don't sample points (within the metavoxel) behind the camera
	int tEntry = ceil(t1 / mvStepSize); // entry index
	int tExit  = floor(t2 / mvStepSize); // exit index
	float3 mvCameraPos = mul(_CameraToMetavoxel, float4(0, 0, 0, 1)); // camera position along this ray (for soft particles)		
	int tCamera = sqrt(dot(mvCameraPos - mvRay.o, mvCameraPos - mvRay.o)) / mvStepSize;
	tEntry = max(tEntry, tCamera);	

	// loop variables
	float3 result = float3(0, 0, 0);
	float transmittance = 1.0f;
	float borderVoxelOffset = rcp(_NumVoxels) * _MetavoxelBorderSize;
	int samples = 0;
	int stepIndex;
	float3 mvRayStep = mvRay.d * mvStepSize,
		   mvRayPos = mvRay.o + tExit * mvRayStep;

	// Sample uniformly in the opposite direction of the ray, starting from the current metavoxel's exit and stopping
	// once we hit the camera (or) are outside the metavoxel. 	
	// Samples are blended back-to-front. (This is orthogonal to the metavoxel raymarch blend mode, which is b/w metavoxels)
	for (stepIndex = tExit; stepIndex >= tEntry; stepIndex--) {			
		float3 samplePos = mvRayPos + 0.5; //[-0.5, 0.5] -->[0, 1]
						
		// adjust for the metavoxel border -- the border voxels are only for filtering
		samplePos = samplePos * (1.0 - 2.0 * borderVoxelOffset) + borderVoxelOffset;  // [0, 1] ---> [offset, 1 - offset]

		// supply 0 derivatives when sampling -- this ensures that the loop doesn't have to unrolled on SM 5.0 (hlsl)
		// due to a gradient instruction (such as tex3D)
		half4 voxelColor = tex3D(_VolumeTexture, samplePos, float3(0,0,0), float3(0,0,0));
		half3 color = voxelColor.rgb;
		half  density = voxelColor.a;

		// if samples are very close to the camera, make them more transparent (a la soft particles)
		if (stepIndex - tCamera < _SoftDistance) {
			// make less dense
			density *= (stepIndex - tCamera) * rcp(_SoftDistance);
		}

		half blendFactor = rcp(1.0 + density);

		result.rgb = lerp(color, result.rgb, blendFactor);
		transmittance *= blendFactor;
						
		mvRayPos -= mvRayStep;
		samples++;
	}		


	// Debug viewer to color code number of samples per ray for this metavoxel
	#if defined(DBG_ON_NUM_SAMPLES)
		return RayMarchSamplesColoring(samples);			
	#endif

	return float4(result.rgb, 1 - transmittance);			
} // frag

ENDCG
} // Pass
}FallBack Off
}