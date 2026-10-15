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

		HLSLINCLUDE

        #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
        #include "Packages/com.unity.render-pipelines.core/Runtime/Utilities/Blit.hlsl"

		TEXTURE2D_X(_AccumTex);
		TEXTURE2D_X(_RevealageTex);
        SAMPLER(sampler_AccumTex);

		// 縮小バッファ用
		TEXTURE2D_X_FLOAT(_WBOIT_DepthTex);     // フル解像度のカメラデプス
		TEXTURE2D_X_FLOAT(_WBOIT_LowDepthTex);  // 縮小したデプス
		float4 _WBOIT_Params;   // x: 縮小率(1/2なら2), y: アップサンプル時のデプス差の閾値(相対)
		float4 _WBOIT_SrcSize;  // xy: 参照するテクスチャのサイズ, zw: 1/サイズ

		float4 ResolveWBOIT(float4 accum, float r)
		{
			#if 1
			// ブレンド毎に分ける場合
			return float4(accum.rgb / clamp(accum.a, 1e-4, 5e4), r);
			#else
			// α値をまとめてチャンネル別でブレンドを分ける場合
			return float4(accum.rgb / clamp(r.y, 1e-4, 5e4), r.w);
			#endif
		}

		// 透視・平行投影どちらでも使える線形デプス
		float LinearDepth(float rawDepth)
		{
			if (unity_OrthoParams.w > 0.5)
			{
				#if UNITY_REVERSED_Z
				rawDepth = 1.0 - rawDepth;
				#endif
				return lerp(_ProjectionParams.y, _ProjectionParams.z, rawDepth);
			}
			return LinearEyeDepth(rawDepth, _ZBufferParams);
		}

		ENDHLSL

		// 背景をサンプルせず (1 - r) * col + r * background をハードウェアブレンドで行う（RenderGraph用）
		Pass {
			Name "WBOIT Composite"
			Blend OneMinusSrcAlpha SrcAlpha

			HLSLPROGRAM

            #pragma vertex Vert
            #pragma fragment Fragment

			float4 Fragment(Varyings i) : SV_Target {
				const float4 accum = SAMPLE_TEXTURE2D_X(_AccumTex, sampler_AccumTex, i.texcoord);
				const float r = SAMPLE_TEXTURE2D_X(_RevealageTex, sampler_AccumTex, i.texcoord).r;
				return ResolveWBOIT(accum, r);
			}

			ENDHLSL
		}

		// 縮小バッファをデプスを考慮してアップサンプルしながら合成
		// 周囲4テクセルのデプスがフル解像度のデプスと近ければバイリニア、離れていれば最もデプスが近いテクセルを使う
		Pass {
			Name "WBOIT Composite Upsample"
			Blend OneMinusSrcAlpha SrcAlpha

			HLSLPROGRAM

            #pragma vertex Vert
            #pragma fragment Fragment

			float4 Fragment(Varyings i) : SV_Target {
				const float depth = LinearDepth(LOAD_TEXTURE2D_X(_WBOIT_DepthTex, uint2(i.positionCS.xy)).r);

				// 縮小バッファ上の位置（テクセル中心基準）
				const float2 lowPos = i.positionCS.xy / _WBOIT_Params.x - 0.5;
				const int2 maxTexel = int2(_WBOIT_SrcSize.xy) - 1;
				const int2 t0 = clamp(int2(floor(lowPos)), 0, maxTexel);
				const int2 t1 = min(t0 + int2(1, 0), maxTexel);
				const int2 t2 = min(t0 + int2(0, 1), maxTexel);
				const int2 t3 = min(t0 + int2(1, 1), maxTexel);

				const float4 diff = abs(float4(
					LinearDepth(LOAD_TEXTURE2D_X(_WBOIT_LowDepthTex, t0).r),
					LinearDepth(LOAD_TEXTURE2D_X(_WBOIT_LowDepthTex, t1).r),
					LinearDepth(LOAD_TEXTURE2D_X(_WBOIT_LowDepthTex, t2).r),
					LinearDepth(LOAD_TEXTURE2D_X(_WBOIT_LowDepthTex, t3).r)) - depth);

				float4 accum;
				float r;
				if (max(max(diff.x, diff.y), max(diff.z, diff.w)) < _WBOIT_Params.y * depth)
				{
					// NOTE: RenderGraphのテクスチャのフィルタ設定に依存しないよう明示的にバイリニアのサンプラーを使う
					const float2 uv = (lowPos + 0.5) * _WBOIT_SrcSize.zw;
					accum = SAMPLE_TEXTURE2D_X_LOD(_AccumTex, sampler_LinearClamp, uv, 0);
					r = SAMPLE_TEXTURE2D_X_LOD(_RevealageTex, sampler_LinearClamp, uv, 0).r;
				}
				else
				{
					int2 nearest = t0;
					float minDiff = diff.x;
					if (diff.y < minDiff) { minDiff = diff.y; nearest = t1; }
					if (diff.z < minDiff) { minDiff = diff.z; nearest = t2; }
					if (diff.w < minDiff) { minDiff = diff.w; nearest = t3; }
					accum = LOAD_TEXTURE2D_X(_AccumTex, nearest);
					r = LOAD_TEXTURE2D_X(_RevealageTex, nearest).r;
				}
				return ResolveWBOIT(accum, r);
			}

			ENDHLSL
		}

		// カメラデプスを縮小（縮小率 x 縮小率 の範囲で最も奥のデプスを採用）
		Pass {
			Name "WBOIT Downsample Depth"
			ZWrite On
			ColorMask 0

			HLSLPROGRAM

            #pragma vertex Vert
            #pragma fragment Fragment

			float Fragment(Varyings i) : SV_Depth {
				const int scale = int(_WBOIT_Params.x);
				const int2 origin = int2(i.positionCS.xy) * scale;
				const int2 maxTexel = int2(_WBOIT_SrcSize.xy) - 1;

				#if UNITY_REVERSED_Z
				float result = 1.0;
				#else
				float result = 0.0;
				#endif
				for (int y = 0; y < scale; ++y)
				{
					for (int x = 0; x < scale; ++x)
					{
						const float d = LOAD_TEXTURE2D_X(_WBOIT_DepthTex, min(origin + int2(x, y), maxTexel)).r;
						#if UNITY_REVERSED_Z
						result = min(result, d);
						#else
						result = max(result, d);
						#endif
					}
				}
				return result;
			}

			ENDHLSL
		}
	}
}
