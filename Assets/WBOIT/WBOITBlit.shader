Shader "WBOIT/Blit"
{
	SubShader{
        Tags { "RenderType" = "Opaque" "RenderPipeline" = "UniversalPipeline"}
        
        Name "WBOIT Blend"
		Cull Off
		ZTest Always
		ZWrite Off
		Blend Off
		//Fog { Mode Off }

		Pass {
			HLSLPROGRAM

            #pragma vertex Vert
            #pragma fragment Fragment
			
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "Packages/com.unity.render-pipelines.core/Runtime/Utilities/Blit.hlsl"
            //#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Debug/DebuggingFullscreen.hlsl"
            //#include "Packages/com.unity.render-pipelines.core/ShaderLibrary/Color.hlsl"

            SAMPLER(sampler_BlitTexture);
            
			TEXTURE2D_X(_AccumTex);
			TEXTURE2D_X(_RevealageTex);
            SAMPLER(sampler_AccumTex);
            //SAMPLER(sampler_RevealageTex);
			
			float4 Fragment(Varyings i) : SV_Target {
                const float4 background = SAMPLE_TEXTURE2D_X(_BlitTexture, sampler_BlitTexture, i.texcoord);
				const float4 accum = SAMPLE_TEXTURE2D_X(_AccumTex, sampler_AccumTex, i.texcoord);
				const float r = SAMPLE_TEXTURE2D_X(_RevealageTex, sampler_AccumTex, i.texcoord).r;
				const float4 col = float4(accum.rgb / clamp(accum.a, 1e-4, 5e4), r);

				return (1.0 - col.a) * col + col.a * background;
			}
			
			ENDHLSL
		}
	}
}
