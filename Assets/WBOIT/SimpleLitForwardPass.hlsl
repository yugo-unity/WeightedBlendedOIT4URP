#ifndef SIMPLE_LIT_OIT_PASS_INCLUDED
#define SIMPLE_LIT_OIT_PASS_INCLUDED

// Custom forward pass for forward renderer

// Material properties, put in UnityPerMaterial cbuffer for SRP compatibility
CBUFFER_START(UnityPerMaterial)
half4 _BaseColor;
float4 _BaseMap_ST;
float _BumpScale;
half3 _EmissionColor;
half4 _SpecularColor;
CBUFFER_END

// URP includes
#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"
#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/DBuffer.hlsl"  // For decals
#ifdef DEBUG_DISPLAY
#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Debug/Debugging3D.hlsl" // Required for debug display
#endif
#ifdef LOD_FADE_CROSSFADE
#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/LODCrossFade.hlsl" // Include LOD Cross Fade implementation if needed
#endif

// Texture samplers
TEXTURE2D(_BaseMap);
SAMPLER(sampler_BaseMap);
TEXTURE2D(_BumpMap);
SAMPLER(sampler_BumpMap);
TEXTURE2D(_EmissionMap);
SAMPLER(sampler_EmissionMap);
TEXTURE2D(_SpecularMap);
SAMPLER(sampler_SpecularMap);

// Properties required for debug display
float4 _BaseMap_TexelSize;
float4 _BaseMap_MipInfo;

// Attributes
struct Attributes
{
    float2 uv                   : TEXCOORD0;
    float4 positionOS           : POSITION;  // Object-space position
    float3 normalOS             : NORMAL;    // Object-space normal
    float4 tangentOS            : TANGENT;   // Object-space tangent
    float2 staticLightmapUV     : TEXCOORD1; // Lightmap UV (static)
#ifdef DYNAMICLIGHTMAP_ON
    float2 dynamicLightmapUV    : TEXCOORD2; // Lightmap UV (dynamic)
#endif
    UNITY_VERTEX_INPUT_INSTANCE_ID
};

// Varyings
struct Varyings
{
    float2 uv                   : TEXCOORD0;

    DECLARE_LIGHTMAP_OR_SH(staticLightmapUV, vertexSH, 1);  // GI (lightmap or ambient light)

    float3 positionWS           : TEXCOORD2;   // World-space position
    half3 normalWS              : TEXCOORD3;   // World-space normal
    half3 tangentWS             : TEXCOORD4;   // World-space tangent
    half3 bitangentWS           : TEXCOORD5;   // World-space bitangent

#ifdef REQUIRES_VERTEX_SHADOW_COORD_INTERPOLATOR
    float4 shadowCoord          : TEXCOORD6;   // Vertex shadow coords if required
#endif
                
#ifdef DYNAMICLIGHTMAP_ON
    float2 dynamicLightmapUV    : TEXCOORD7;   // Dynamic lightmap UVs
#endif

    // Store fog factor + vertex light (if enabled) in same TEXCOORD8
#if _ADDITIONAL_LIGHTS_VERTEX    
    half4 fogFactorVertexLight  : TEXCOORD8;   // Fog factor (x) + vertex light (yzw)
#else
    half fogFactor              : TEXCOORD8;   // Fog Factor 
#endif

    float4 positionCS           : SV_POSITION; // Clip-space position
    float cameraZ : TEXCOORD9;

    UNITY_VERTEX_INPUT_INSTANCE_ID
    UNITY_VERTEX_OUTPUT_STEREO
};

// ====== Weight functions

inline float d(float z)
{
    float zNear = 0.1;
    float zFar  = 500;
    return ((zNear * zFar) / z - zFar) / (zNear - zFar);  
}

inline float CalcWeight(float z, float alpha)
{
    // 元の数式ままなので max/min を clamp に置き換えたり整理可能
    // 近似曲線はNVIDIAのドキュメント参照
    // https://jcgt.org/published/0002/02/09/
    #ifdef EQ7
    // (eq.7)
    return alpha * max(1e-2, min(3 * 1e3, 10.0/(1e-5 + pow(z/5, 2) + pow(z/200, 6))));
    #elif EQ8
    // (eq.8)
    return alpha * max(1e-2, min(3 * 1e3, 10.0/(1e-5 + pow(z/10, 3) + pow(z/200, 6))));
    #elif EQ9    
    // (eq.9)
    return alpha * max(1e-2, min(3 * 1e3, 0.03/(1e-5 + pow(z/200, 4))));
    //#elif EQ10
    #else
    // eq.10
    return alpha * max(1e-2, 3 * 1e3 * (1 - pow(d(z), 3)));
    #endif
}

// ====== Lighting functions

// Diffuse
half3 LightingDiffuse(Light light, float3 normalWS)
{
    half3 lightColor = light.color * light.distanceAttenuation * light.shadowAttenuation;

    // Diffuse
    float NDL = saturate(dot(normalWS, light.direction));
    half3 diffuseColor = (lightColor * NDL);

    return diffuseColor;
}

// Specular
half3 LightingSpecular(Light light, float3 normalWS, float3 viewDirectionWS, half3 specular, float smoothness)
{
    half3 lightColor = light.color * light.distanceAttenuation * light.shadowAttenuation;

    // Specular
    float3 halfVector = normalize(light.direction + viewDirectionWS);
    float NDH = saturate(dot(normalWS, halfVector));
    float specularFactor = pow(NDH, smoothness);
    half3 specularColor = lightColor * specular * specularFactor;

    return specularColor;
}

// ====== Vertex functions

// Vert
Varyings LitForwardVert(Attributes input)
{
    Varyings output;

    // GPU instancing
    UNITY_SETUP_INSTANCE_ID(input);
    UNITY_TRANSFER_INSTANCE_ID(input, output);
    // Stereo
    UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(output);

    // Transformations
    // See Packages/com.unity.render-pipelines.universal/ShaderLibrary/ShaderVariablesFunctions.hlsl for helper functions
    VertexPositionInputs positionInputs = GetVertexPositionInputs(input.positionOS.xyz);
    float4 positionCS = positionInputs.positionCS;
    float3 positionWS = positionInputs.positionWS;
    VertexNormalInputs normalInputs = GetVertexNormalInputs(input.normalOS);
    float3 normalWS = normalInputs.normalWS;
    float3 tangentWS = normalInputs.tangentWS;
    float3 bitangentWS = normalInputs.bitangentWS;

    // Set output
    OUTPUT_LIGHTMAP_UV(input.staticLightmapUV, unity_LightmapST, output.staticLightmapUV);
    OUTPUT_SH(normalWS, output.vertexSH);
    output.uv = TRANSFORM_TEX(input.uv, _BaseMap);
    output.positionCS = positionCS;
    output.positionWS = positionWS;
    output.normalWS = normalWS;
    output.tangentWS = tangentWS;
    output.bitangentWS = bitangentWS;
#ifdef REQUIRES_VERTEX_SHADOW_COORD_INTERPOLATOR
    // Vertex shadow coords if required
    output.shadowCoord = TransformWorldToShadowCoord(positionWS);
#endif
#ifdef DYNAMICLIGHTMAP_ON
    // Dynamic lightmap
    output.dynamicLightmapUV = input.dynamicLightmapUV.xy * unity_DynamicLightmapST.xy + unity_DynamicLightmapST.zw;
#endif

    // Fog + vertex lighting
    half fogFactor = ComputeFogFactor(positionCS.z);
#ifdef _ADDITIONAL_LIGHTS_VERTEX

#if _LIGHT_LAYERS
    // Get rendering layer if feature is enabled
    uint renderingLayer = GetMeshRenderingLayer();
#endif

    half3 vertexLight = 0;
    // Loop through additional lights to get vertex lighting
    uint additionalLightCount = GetAdditionalLightsCount();
    for (uint lightIndex = 0; lightIndex < additionalLightCount; lightIndex++)
    {
        Light light = GetAdditionalLight(lightIndex, positionWS);

#if _LIGHT_LAYERS
        // If rendering layers are enabled, only process light if renderer's layer is included
        if (IsMatchingLightLayer(light.layerMask, renderingLayer))
#endif
        {
            vertexLight += LightingDiffuse(light, normalWS);
        }
    }

    // Output fogFactor + vertexLight variable
    output.fogFactorVertexLight = half4(fogFactor, vertexLight);
#else
    // No vertex lights, so fogFactor singular variable
    output.fogFactor = fogFactor;
#endif

    // for Weighted Blend
    // clampいらないかも
    output.cameraZ = clamp(abs(mul(UNITY_MATRIX_MV, input.positionOS).z), 0.1, 500);

    return output;
}

// ====== Fragment functions

// Get lit color
half4 Lighting(InputData inputData, SurfaceData surfaceData)
{
    // Basic BlinnPhong lighting

    float smoothness = exp2(11 * surfaceData.smoothness);

    // NOTE: Light cookies are not implemented in this sample

    // Get rendering layer if feature is enabled
#if _LIGHT_LAYERS
    uint renderingLayer = GetMeshRenderingLayer();
#endif

    // Main light
    half3 mainLightDiffuseColor = 0;
    half3 mainLightSpecularColor = 0;
    Light mainLight = GetMainLight(inputData.shadowCoord, inputData.positionWS, inputData.shadowMask);
    MixRealtimeAndBakedGI(mainLight, inputData.normalWS, inputData.bakedGI);
#if _LIGHT_LAYERS
    // If rendering layers are enabled, only process light if renderer's layer is included
    if (IsMatchingLightLayer(mainLight.layerMask, renderingLayer))
#endif
    {
        // Diffuse
        mainLightDiffuseColor += LightingDiffuse(mainLight, inputData.normalWS) + inputData.vertexLighting;
        // Specular
        mainLightSpecularColor += LightingSpecular(mainLight, inputData.normalWS, inputData.viewDirectionWS, surfaceData.specular, smoothness);
    }

    // Additional lights (only for per-pixel lights)
    half3 additionalLightsDiffuseColor = 0;
    half3 additionalLightsSpecularColor = 0;
#ifdef _ADDITIONAL_LIGHTS
    // In URP, additional lights are handled in same pass with loop

    #if USE_FORWARD_PLUS // (USE_FORWARD_PLUS is defined when _FORWARD_PLUS keyword is enabled)
    // Loop through additional directional lights used Forward+
    for (uint lightIndex = 0; lightIndex < min(URP_FP_DIRECTIONAL_LIGHTS_COUNT, MAX_VISIBLE_LIGHTS); lightIndex++)
    {
        FORWARD_PLUS_SUBTRACTIVE_LIGHT_CHECK

        Light light = GetAdditionalLight(lightIndex, inputData.positionWS, inputData.shadowMask);

#if _LIGHT_LAYERS
        // If rendering layers are enabled, only process light if renderer's layer is included
        if (IsMatchingLightLayer(light.layerMask, renderingLayer))
#endif
        {
            // Diffuse
            additionalLightsDiffuseColor += LightingDiffuse(light, inputData.normalWS) + inputData.vertexLighting;
            // Specular
            additionalLightsSpecularColor += LightingSpecular(light, inputData.normalWS, inputData.viewDirectionWS, surfaceData.specular, smoothness);
        }
    }
    #endif

    // Additional light count (returns 0 in Forward+)
    uint additionalLightCount = GetAdditionalLightsCount();

    // Macro provided by URP to loop through additional lights (point, spot, etc) in
    // both standard Forward and Forward+ (additionalLightCount is only used in Forward)
    // Provides lightIndex to fetch light with GetAdditionalLight
    // Forward: Loops through found additional lights
    // Forward+: Iterates through clusters to fetch lights
    // See RealtimeLights.hlsl for implementation
    LIGHT_LOOP_BEGIN(additionalLightCount)
        Light light = GetAdditionalLight(lightIndex, inputData.positionWS, inputData.shadowMask);

#if _LIGHT_LAYERS
        // If rendering layers are enabled, only process light if renderer's layer is included
        if (IsMatchingLightLayer(light.layerMask, renderingLayer))
#endif
        {
            // Diffuse
            additionalLightsDiffuseColor += LightingDiffuse(light, inputData.normalWS) + inputData.vertexLighting;
            // Specular
            additionalLightsSpecularColor += LightingSpecular(light, inputData.normalWS, inputData.viewDirectionWS, surfaceData.specular, smoothness);
        }
    LIGHT_LOOP_END
#endif

    // Final color
#ifdef DEBUG_DISPLAY
    // For Rendering Debugger, add colors for features that are enabled
    half3 finalColor = 0;

    // This shader does not support AO, so DEBUGLIGHTINGFEATUREFLAGS_AMBIENT_OCCLUSION is not checked

    if (IsLightingFeatureEnabled(DEBUGLIGHTINGFEATUREFLAGS_MAIN_LIGHT))
    {
        finalColor += mainLightDiffuseColor;
    }

    if (IsLightingFeatureEnabled(DEBUGLIGHTINGFEATUREFLAGS_ADDITIONAL_LIGHTS))
    {
        finalColor += additionalLightsDiffuseColor;
    }

    if (IsLightingFeatureEnabled(DEBUGLIGHTINGFEATUREFLAGS_VERTEX_LIGHTING))
    {
        finalColor += inputData.vertexLighting;
    }

    if (IsLightingFeatureEnabled(DEBUGLIGHTINGFEATUREFLAGS_GLOBAL_ILLUMINATION))
    {
        finalColor += inputData.bakedGI;
    }

    finalColor *= surfaceData.albedo;

    if (IsLightingFeatureEnabled(DEBUGLIGHTINGFEATUREFLAGS_EMISSION))
    {
        finalColor += surfaceData.emission;
    }

    half3 debugSpecularColor = 0;

    if (IsLightingFeatureEnabled(DEBUGLIGHTINGFEATUREFLAGS_MAIN_LIGHT))
    {
        debugSpecularColor += mainLightSpecularColor;
    }

    if (IsLightingFeatureEnabled(DEBUGLIGHTINGFEATUREFLAGS_ADDITIONAL_LIGHTS))
    {
        debugSpecularColor += additionalLightsSpecularColor;
    }

    finalColor += debugSpecularColor;
#else
    half3 finalColor = (mainLightDiffuseColor + additionalLightsDiffuseColor + inputData.vertexLighting + inputData.bakedGI) * surfaceData.albedo + surfaceData.emission;
    finalColor += (mainLightSpecularColor + additionalLightsSpecularColor);
#endif

    return half4(finalColor, surfaceData.alpha);
}

// Frag
// MRT for Weighted Blended
void LitForwardFrag(Varyings input, out float4 color : SV_Target0, out float4 alpha : SV_Target1)
{
    // Instancing
    UNITY_SETUP_INSTANCE_ID(input);
    // Stereo
    UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(input);

#ifdef LOD_FADE_CROSSFADE
    // Check LOD cross fade first, as it uses clip operation to discard faded area
    LODFadeCrossFade(input.positionCS);
#endif

    //half4 color;

    float2 uv = input.uv;

    // Helper functions to sample base map, normal map, emission, specular can also be found in
    // Packages/com.unity.render-pipelines.universal/ShaderLibrary/SurfaceInput.hlsl

    // Sample base map + color
    half4 baseMap = SAMPLE_TEXTURE2D(_BaseMap, sampler_BaseMap, uv);
    color = baseMap * _BaseColor;

    // Sample normal map
#if BUMP_SCALE_NOT_SUPPORTED
    half3 normalTS = UnpackNormal(SAMPLE_TEXTURE2D(_BumpMap, sampler_BumpMap, uv));
#else
    half3 normalTS = UnpackNormalScale(SAMPLE_TEXTURE2D(_BumpMap, sampler_BumpMap, uv), _BumpScale);
#endif
    half3 normalWS = normalize(mul(normalTS, float3x3(input.tangentWS, input.bitangentWS, input.normalWS)));

    // Sample emission map
    half3 emission = SAMPLE_TEXTURE2D(_EmissionMap, sampler_EmissionMap, uv).rgb * _EmissionColor;

    // Sample specular map
    half4 specular = SAMPLE_TEXTURE2D(_SpecularMap, sampler_SpecularMap, uv) * _SpecularColor;

    // Shadow coord
#ifdef REQUIRES_VERTEX_SHADOW_COORD_INTERPOLATOR
    // Use vertex shadow coords if required
    float4 shadowCoord = input.shadowCoord;
#elif defined(MAIN_LIGHT_CALCULATE_SHADOWS) // MAIN_LIGHT_CALCULATE_SHADOWS = defined(_MAIN_LIGHT_SHADOWS) || defined(_MAIN_LIGHT_SHADOWS_CASCADE) || defined(_MAIN_LIGHT_SHADOWS_SCREEN)
    // Otherwise, set up for per-pixel shadow coords
    float4 shadowCoord = TransformWorldToShadowCoord(input.positionWS);
#else
    float4 shadowCoord = 0;
#endif

    // Basic lighting
    // Built-in lighting functions can be found in Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl
    // Construct InputData struct
    InputData inputData = (InputData)0;
    inputData.positionCS = input.positionCS;
    inputData.positionWS = input.positionWS;
    inputData.normalWS = normalWS;
    inputData.viewDirectionWS = normalize(GetWorldSpaceViewDir(input.positionWS));
    inputData.shadowCoord = shadowCoord;
    inputData.normalizedScreenSpaceUV = GetNormalizedScreenSpaceUV(input.positionCS);
    inputData.shadowMask = SAMPLE_SHADOWMASK(input.staticLightmapUV);
    // Vertex lighting and fog
#ifdef _ADDITIONAL_LIGHTS_VERTEX
    inputData.vertexLighting = input.fogFactorVertexLight.yzw; // From fogFactorVertexLight combined variable
    inputData.fogCoord = InitializeInputDataFog(float4(input.positionWS, 1.0), input.fogFactorVertexLight.x);
#else
    inputData.vertexLighting = 0;
    inputData.fogCoord = InitializeInputDataFog(float4(input.positionWS, 1.0), input.fogFactor);
#endif
    // Lightmaps
#ifdef DYNAMICLIGHTMAP_ON
    inputData.bakedGI = SAMPLE_GI(input.staticLightmapUV, input.dynamicLightmapUV, input.vertexSH, normalWS);
#else
    inputData.bakedGI = SAMPLE_GI(input.staticLightmapUV, input.vertexSH, normalWS);
#endif
    // For Rendering Debugger
#ifdef DEBUG_DISPLAY
#ifdef DYNAMICLIGHTMAP_ON
    inputData.dynamicLightmapUV = input.dynamicLightmapUV.xy;
#endif
#ifdef LIGHTMAP_ON
    inputData.staticLightmapUV = input.staticLightmapUV;
#else
    inputData.vertexSH = input.vertexSH;
#endif
    SETUP_DEBUG_TEXTURE_DATA(inputData, input.uv, _BaseMap);
#endif
                
    // Construct SurfaceData struct
    SurfaceData surfaceData = (SurfaceData)0;
    surfaceData.albedo = color.rgb;
    surfaceData.alpha = color.a;
    surfaceData.emission = emission;
    surfaceData.metallic = 0;
    surfaceData.occlusion = 0;
    surfaceData.smoothness = specular.a;
    surfaceData.specular = specular.rgb;
    surfaceData.normalTS = normalTS;

#ifdef _DBUFFER
    // Accept decal projection if enabled
    ApplyDecalToSurfaceData(input.positionCS, surfaceData, inputData);
#endif

#ifdef DEBUG_DISPLAY
    // Stop here and return debug display color Rendering Debugger is enabled with modes that can override

    // Manually handle DEBUGLIGHTINGMODE_LIGHTING_WITHOUT_NORMAL_MAPS and DEBUGLIGHTINGMODE_REFLECTIONS

    // These two modes internally depend upon a local _NORMALMAP keyword being defined
    // Default URP shaders enable/disable _NORMALMAP in the ShaderGUI (BaseShaderGUI.cs)
    // Since this sample does not include a ShaderGUI, we must handle these modes manually

    // Ignore normal map values for normals when DEBUGLIGHTINGMODE_LIGHTING_WITHOUT_NORMAL_MAPS or DEBUGLIGHTINGMODE_REFLECTIONS is enabled
    if (_DebugLightingMode == DEBUGLIGHTINGMODE_LIGHTING_WITHOUT_NORMAL_MAPS || _DebugLightingMode == DEBUGLIGHTINGMODE_REFLECTIONS) {
        inputData.normalWS = normalize(input.normalWS);
    }

    half4 debugColor;
    if (CanDebugOverrideOutputColor(inputData, surfaceData, debugColor))
    {
        return debugColor;
    }
#endif

    // Lighting
    color = Lighting(inputData, surfaceData);

    // Mix fog
    color.rgb = MixFog(color.rgb, inputData.fogCoord);

    // Weighted Blended.........
    //return color;
    const float weight = CalcWeight(input.cameraZ, color.a);
    #if 1
    // ブレンド毎に分ける場合
    alpha = color.aaaa;
    color = float4(color.rgb * color.a * weight, color.a * weight);
    #else
    // α値をまとめてチャンネル別でブレンドを分ける場合
    float al = color.a;
    color = float4(color.rgb * color.a * weight, color.a * weight);
    alpha = float4(0,0,0,0);
    alpha.yz = color.a;
    alpha.w = al;
    #endif
}

#endif
