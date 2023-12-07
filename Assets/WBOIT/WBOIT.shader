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
			Blend 0 One One
			Blend 1 Zero OneMinusSrcAlpha

			HLSLPROGRAM

            #pragma vertex LitForwardVert
            #pragma fragment LitForwardFrag

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "SimpleLitForwardPass.hlsl"

			ENDHLSL
		}
	}
}