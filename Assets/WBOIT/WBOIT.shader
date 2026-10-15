Shader "WBOIT/SimpleLitTransparent"
{
    Properties {
        [MainColor] _BaseColor("Base Color", Color) = (1, 1, 1, 1)
        [MainTexture] _BaseMap("Base Map", 2D) = "white" {}

        // Normal map
        _BumpScale("Normal Scale", Float) = 1.0
        [Normal] _BumpMap("Normal Map", 2D) = "bump" {}

        // Specular map
        [HDR] _SpecularColor("Specular Color (RGB: Color, A: Smoothness)", Color) = (1, 1, 1, 1)
        _SpecularMap("Specular Map", 2D) = "white" {}

        // Emission map
        [HDR] _EmissionColor("Emission Color", Color) = (0, 0, 0)
        _EmissionMap("Emission Map", 2D) = "white" {}

        [Enum(Both, 0, Back, 1, Front, 2)] _Cull("Render Face", Float) = 0
	}
    
	SubShader {
		Tags {
			"Queue"="Transparent"
			"IgnoreProjector"="True"
			"RenderType"="Transparent"
			"RenderPipeline" = "UniversalPipeline"
		}

		Pass {
			Tags { "LightMode" = "WeightedBlendedOIT" }

			Cull [_Cull]
			ZWrite Off
			
			// https://docs.unity3d.com/ja/2022.3/Manual/SL-Blend.html
			// RenderTargetに対してブレンドを指定
			Blend 0 One One
			Blend 1 Zero OneMinusSrcAlpha
			// α値に対してブレンドを指定
			//Blend One One, Zero OneMinusSrcAlpha

			HLSLPROGRAM

            #pragma vertex LitForwardVert
            #pragma fragment LitForwardFrag

            //#pragma shader_feature_fragment EQ7 EQ8 EQ9
            #define EQ7

            // 蓄積パスの検討余地 (未適用)
            // NOTE: 計測ではフラグメントシェーダーを定数出力にしても蓄積パスの時間はほぼ変わらず (重なりの多いシーンで差なし)、
            //       負荷は重なったピクセル数とブレンドの書き込みが支配的だったため、以下はいずれも効果が小さい見込み
            //       重なりを減らす Cull Back や縮小バッファの方が効く
            // - 未設定テクスチャのサンプル省略: Normal/Emission/Specular は未設定でも既定テクスチャをサンプルしている
            //   URP 同様に _NORMALMAP / _EMISSION / _SPECGLOSSMAP の shader_feature_local_fragment で省ける (重なり1層ごとに3サンプル減)
            // - ほぼ透明なピクセルの破棄: color.a < 1/255 で clip すればブレンドの書き込みを省ける
            //   ZWrite Off なので Early-Z への影響は小さい想定だが、discard のコストが勝る GPU もあるため要計測
            // - ライティングの half 化: 法線の正規化やスペキュラーの pow を half で計算する
            //   ただし蓄積パスが帯域/重なり律速なら ALU 削減の効果は小さい

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "SimpleLitForwardPass.hlsl"

			ENDHLSL
		}
	}
}
