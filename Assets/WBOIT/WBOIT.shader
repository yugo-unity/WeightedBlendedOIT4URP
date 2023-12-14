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

			Cull Off
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

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "SimpleLitForwardPass.hlsl"

			ENDHLSL
		}
	}
}
