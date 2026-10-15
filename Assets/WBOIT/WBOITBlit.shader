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

		// 背景をサンプルせず (1 - r) * col + r * background をハードウェアブレンドで行う（RenderGraph用）
		Pass {
			Name "WBOIT Composite"
			Blend OneMinusSrcAlpha SrcAlpha

			HLSLPROGRAM

            #pragma vertex Vert
            #pragma fragment Fragment

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "Packages/com.unity.render-pipelines.core/Runtime/Utilities/Blit.hlsl"

			TEXTURE2D_X(_AccumTex);
			TEXTURE2D_X(_RevealageTex);
            SAMPLER(sampler_AccumTex);

			float4 Fragment(Varyings i) : SV_Target {
				const float4 accum = SAMPLE_TEXTURE2D_X(_AccumTex, sampler_AccumTex, i.texcoord);
				const float r = SAMPLE_TEXTURE2D_X(_RevealageTex, sampler_AccumTex, i.texcoord).r;
				#if 1
				// ブレンド毎に分ける場合
				return float4(accum.rgb / clamp(accum.a, 1e-4, 5e4), r);
				#else
				// α値をまとめてチャンネル別でブレンドを分ける場合
				return float4(accum.rgb / clamp(r.y, 1e-4, 5e4), r.w);
				#endif
			}

			ENDHLSL
		}
	}
}
