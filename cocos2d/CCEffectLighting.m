//
//  CCEffectLighting.m
//  cocos2d-ios
//
//  Created by Thayer J Andrews on 10/2/14.
//
//

#import "CCEffectLighting.h"

#import "CCDirector.h"
#import "CCEffectUtils.h"
#import "CCLightCollection.h"
#import "CCLightGroups.h"
#import "CCLightNode.h"
#import "CCRenderer.h"
#import "CCScene.h"
#import "CCSpriteFrame.h"
#import "CCTexture.h"

#import "CCEffect_Private.h"
#import "CCSprite_Private.h"


typedef struct _CCLightKey
{
    NSUInteger pointLightMask;
    NSUInteger directionalLightMask;

} CCLightKey;

static const NSUInteger CCEffectLightingMaxLightCount = 8;

static CCLightKey CCLightKeyMake(NSArray *lights);
static BOOL CCLightKeyCompare(CCLightKey a, CCLightKey b);
static float conditionShininess(float shininess);


@interface CCEffectLighting ()
@property (nonatomic, strong) NSNumber *conditionedShininess;
@end


@interface CCEffectLightingImpl : CCEffectImpl

@property (nonatomic, weak) CCEffectLighting *interface;
@property (nonatomic, assign) CCLightGroupMask groupMask;
@property (nonatomic, assign) BOOL groupMaskDirty;
@property (nonatomic, copy) NSArray *closestLights;
@property (nonatomic, assign) CCLightKey lightKey;
@property (nonatomic, readonly) BOOL needsSpecular;
@property (nonatomic, assign) BOOL shaderHasSpecular;
@property (nonatomic, assign) BOOL shaderHasNormalMap;

@end


@implementation CCEffectLightingImpl

-(id)initWithInterface:(CCEffectLighting *)interface
{
    if((self = [super init]))
    {
        _groupMask = CCLightCollectionAllGroups;
        _groupMaskDirty = YES;
        _closestLights = nil;
        
        _lightKey = CCLightKeyMake(nil);
        _shaderHasSpecular = NO;
        _shaderHasNormalMap = NO;

        self.interface = interface;
        self.debugName = @"CCEffectLightingImpl";
    }
    return self;
}

+(NSMutableArray *)buildFragmentFunctionsWithLights:(NSArray*)lights normalMap:(BOOL)needsNormalMap specular:(BOOL)needsSpecular
{
    CCEffectFunctionInput *input = [[CCEffectFunctionInput alloc] initWithType:@"vec4" name:@"inputValue" initialSnippet:CCEffectDefaultInitialInputSnippet snippet:CCEffectDefaultInputSnippet];
    
    NSMutableString *effectBody = [[NSMutableString alloc] init];
    [effectBody appendString:CC_GLSL(
                                     vec4 lightColor;
                                     vec4 lightSpecularColor;
                                     vec4 diffuseSum = u_globalAmbientColor;
                                     vec4 specularSum = vec4(0,0,0,0);
                                     
                                     vec3 worldSpaceLightDir;
                                     vec3 halfAngleDir;
                                     
                                     float lightDist;
                                     float falloffTermA;
                                     float falloffTermB;
                                     float falloffSelect;
                                     float falloffTerm;
                                     float diffuseTerm;
                                     float specularTerm;
                                     float composedAlpha = inputValue.a;
                                     )];

    if (needsNormalMap)
    {
        [effectBody appendString:CC_GLSL(
                                         // Index the normal map and expand the color value from [0..1] to [-1..1]
                                         vec4 normalMap = texture2D(cc_NormalMapTexture, cc_FragTexCoord2);
                                         vec3 tangentSpaceNormal = normalize(normalMap.xyz * 2.0 - 1.0);
                                         
                                         // Convert the normal vector from tangent space to world space
                                         vec3 worldSpaceNormal = normalize(vec3(u_worldSpaceTangent, 0.0) * tangentSpaceNormal.x + vec3(u_worldSpaceBinormal, 0.0) * tangentSpaceNormal.y + vec3(0.0, 0.0, tangentSpaceNormal.z));

                                         composedAlpha *= normalMap.a;
                                         )];
    }
    else
    {
        [effectBody appendString:@"vec3 worldSpaceNormal = vec3(0,0,1);\n"];
    }
    
    [effectBody appendString:CC_GLSL(
                                     if (composedAlpha == 0.0)
                                     {
                                         return vec4(0,0,0,0);
                                     }
                                     )];
    
    for (NSUInteger lightIndex = 0; lightIndex < lights.count; lightIndex++)
    {
        CCLightNode *light = lights[lightIndex];
        if (light.type == CCLightDirectional)
        {
            [effectBody appendFormat:@"worldSpaceLightDir = v_worldSpaceLightDir%lu.xyz;\n", (unsigned long)lightIndex];
            [effectBody appendFormat:@"lightColor = u_lightColor%lu;\n", (unsigned long)lightIndex];
            if (needsSpecular)
            {
                [effectBody appendFormat:@"lightSpecularColor = u_lightSpecularColor%lu;\n", (unsigned long)lightIndex];
            }
        }
        else
        {
            [effectBody appendFormat:@"worldSpaceLightDir = normalize(v_worldSpaceLightDir%lu.xyz);\n", (unsigned long)lightIndex];
            [effectBody appendFormat:@"lightDist = length(v_worldSpaceLightDir%lu.xy);\n", (unsigned long)lightIndex];
            
            [effectBody appendFormat:@"falloffTermA = clamp((lightDist * u_lightFalloff%lu.y + 1.0), 0.0, 1.0);\n", (unsigned long)lightIndex];
            [effectBody appendFormat:@"falloffTermB = clamp((lightDist * u_lightFalloff%lu.z + u_lightFalloff%lu.w), 0.0, 1.0);\n", (unsigned long)lightIndex, (unsigned long)lightIndex];
            [effectBody appendFormat:@"falloffSelect = step(u_lightFalloff%lu.x, lightDist);\n", (unsigned long)lightIndex];
            [effectBody appendFormat:@"falloffTerm = (1.0 - falloffSelect) * falloffTermA + falloffSelect * falloffTermB;\n"];

            [effectBody appendFormat:@"lightColor = u_lightColor%lu * falloffTerm;\n", (unsigned long)lightIndex];
            if (needsSpecular)
            {
                [effectBody appendFormat:@"lightSpecularColor = u_lightSpecularColor%lu * falloffTerm;\n", (unsigned long)lightIndex];
            }
        }
        [effectBody appendString:@"diffuseTerm = max(0.0, dot(worldSpaceNormal, worldSpaceLightDir));\n"];
        [effectBody appendString:@"diffuseSum += lightColor * diffuseTerm;\n"];
        
        if (needsSpecular)
        {
            [effectBody appendString:@"halfAngleDir = (2.0 * dot(worldSpaceLightDir, worldSpaceNormal) * worldSpaceNormal - worldSpaceLightDir);\n"];
            [effectBody appendString:@"specularTerm = max(0.0, dot(halfAngleDir, vec3(0,0,1))) * step(0.0, diffuseTerm);\n"];
            [effectBody appendString:@"specularSum += lightSpecularColor * pow(specularTerm, u_specularExponent);\n"];
        }
    }
    [effectBody appendString:@"vec4 resultColor = diffuseSum * inputValue;\n"];
    if (needsSpecular)
    {
        [effectBody appendString:@"resultColor += specularSum * u_specularColor;\n"];
    }
    [effectBody appendString:@"return vec4(resultColor.xyz, inputValue.a);\n"];
    
    CCEffectFunction* fragmentFunction = [[CCEffectFunction alloc] initWithName:@"lightingEffectFrag" body:effectBody inputs:@[input] returnType:@"vec4"];
    return [NSMutableArray arrayWithObject:fragmentFunction];
}

+(NSMutableArray *)buildVertexFunctionsWithLights:(NSArray*)lights
{
    NSMutableString *effectBody = [[NSMutableString alloc] init];
    for (NSUInteger lightIndex = 0; lightIndex < lights.count; lightIndex++)
    {
        CCLightNode *light = lights[lightIndex];
        
        if (light.type == CCLightDirectional)
        {
            [effectBody appendFormat:@"v_worldSpaceLightDir%lu = u_lightVector%lu;", (unsigned long)lightIndex, (unsigned long)lightIndex];
        }
        else
        {
            [effectBody appendFormat:@"v_worldSpaceLightDir%lu = u_lightVector%lu - (u_ndcToWorld * cc_Position).xyz;", (unsigned long)lightIndex, (unsigned long)lightIndex];
        }
    }
    [effectBody appendString:@"return cc_Position;"];
    
    CCEffectFunction *vertexFunction = [[CCEffectFunction alloc] initWithName:@"lightingEffectVtx" body:effectBody inputs:nil returnType:@"vec4"];
    return [NSMutableArray arrayWithObject:vertexFunction];
}

-(void)buildRenderPasses
{
    __weak CCEffectLightingImpl *weakSelf = self;
    
    CCEffectRenderPass *pass0 = [[CCEffectRenderPass alloc] init];
    pass0.debugLabel = @"CCEffectLighting pass 0";
    pass0.shader = self.shader;
    pass0.beginBlocks = @[[^(CCEffectRenderPass *pass, CCEffectRenderPassInputs *passInputs){
        
        passInputs.shaderUniforms[CCShaderUniformMainTexture] = passInputs.previousPassTexture;
        passInputs.shaderUniforms[CCShaderUniformPreviousPassTexture] = passInputs.previousPassTexture;
        passInputs.shaderUniforms[CCShaderUniformTexCoord1Center] = [NSValue valueWithGLKVector2:passInputs.texCoord1Center];
        passInputs.shaderUniforms[CCShaderUniformTexCoord1Extents] = [NSValue valueWithGLKVector2:passInputs.texCoord1Extents];

        GLKMatrix4 nodeLocalToWorld = CCEffectUtilsMat4FromAffineTransform(passInputs.sprite.nodeToWorldTransform);
        GLKMatrix4 ndcToWorld = GLKMatrix4Multiply(nodeLocalToWorld, passInputs.ndcToNodeLocal);
        

        GLKMatrix2 tangentMatrix = CCEffectUtilsMatrix2InvertAndTranspose(GLKMatrix4GetMatrix2(nodeLocalToWorld), nil);
        GLKVector2 reflectTangent = GLKVector2Normalize(CCEffectUtilsMatrix2MultiplyVector2(tangentMatrix, GLKVector2Make(1.0f, 0.0f)));
        GLKVector2 reflectBinormal = GLKVector2Make(-reflectTangent.y, reflectTangent.x);

        passInputs.shaderUniforms[weakSelf.uniformTranslationTable[@"u_worldSpaceTangent"]] = [NSValue valueWithGLKVector2:reflectTangent];
        passInputs.shaderUniforms[weakSelf.uniformTranslationTable[@"u_worldSpaceBinormal"]] = [NSValue valueWithGLKVector2:reflectBinormal];

        
        // Matrix for converting NDC (normalized device coordinates (aka normalized render target coordinates)
        // to node local coordinates.
        passInputs.shaderUniforms[weakSelf.uniformTranslationTable[@"u_ndcToWorld"]] = [NSValue valueWithGLKMatrix4:ndcToWorld];

        for (NSUInteger lightIndex = 0; lightIndex < weakSelf.closestLights.count; lightIndex++)
        {
            CCLightNode *light = weakSelf.closestLights[lightIndex];
            
            // Get the transform from the light's coordinate space to the effect's coordinate space.
            GLKMatrix4 lightNodeToWorld = CCEffectUtilsMat4FromAffineTransform(light.nodeToWorldTransform);
            
            // Compute the light's position in the effect node's coordinate system.
            GLKVector4 lightVector = GLKVector4Make(0.0f, 0.0f, 0.0f, 0.0f);
            if (light.type == CCLightDirectional)
            {
                lightVector = GLKVector4Normalize(GLKMatrix4MultiplyVector4(lightNodeToWorld, GLKVector4Make(0.0f, 1.0f, light.depth, 0.0f)));
            }
            else
            {
                lightVector = GLKMatrix4MultiplyVector4(lightNodeToWorld, GLKVector4Make(light.anchorPointInPoints.x, light.anchorPointInPoints.y, light.depth, 1.0f));

                float scale0 = GLKVector4Length(GLKMatrix4GetColumn(lightNodeToWorld, 0));
                float scale1 = GLKVector4Length(GLKMatrix4GetColumn(lightNodeToWorld, 1));
                float maxScale = MAX(scale0, scale1);

                float cutoffRadius = light.cutoffRadius * maxScale;

                GLKVector4 falloffTerms = GLKVector4Make(0.0f, 0.0f, 0.0f, 1.0f);
                if (cutoffRadius > 0.0f)
                {
                    float xIntercept = cutoffRadius * light.halfRadius;
                    float r1 = 2.0f * xIntercept;
                    float r2 = cutoffRadius;
                    
                    falloffTerms.x = xIntercept;
                    
                    if (light.halfRadius > 0.0f)
                    {
                        falloffTerms.y = -1.0f / r1;
                    }
                    else
                    {
                        falloffTerms.y = 0.0f;
                    }
                    
                    if (light.halfRadius < 1.0f)
                    {
                        falloffTerms.z = -0.5f / (r2 - xIntercept);
                        falloffTerms.w = 0.5f - xIntercept * falloffTerms.z;
                    }
                    else
                    {
                        falloffTerms.z = 0.0f;
                        falloffTerms.w = 0.0f;
                    }
                }
                
                NSString *lightFalloffLabel = [NSString stringWithFormat:@"u_lightFalloff%lu", (unsigned long)lightIndex];
                passInputs.shaderUniforms[weakSelf.uniformTranslationTable[lightFalloffLabel]] = [NSValue valueWithGLKVector4:falloffTerms];
            }
            
            // Compute the real light color based on color and intensity.
            GLKVector4 lightColor = GLKVector4MultiplyScalar(light.color.glkVector4, light.intensity);
            
            NSString *lightColorLabel = [NSString stringWithFormat:@"u_lightColor%lu", (unsigned long)lightIndex];
            passInputs.shaderUniforms[weakSelf.uniformTranslationTable[lightColorLabel]] = [NSValue valueWithGLKVector4:lightColor];

            NSString *lightVectorLabel = [NSString stringWithFormat:@"u_lightVector%lu", (unsigned long)lightIndex];
            passInputs.shaderUniforms[weakSelf.uniformTranslationTable[lightVectorLabel]] = [NSValue valueWithGLKVector3:GLKVector3Make(lightVector.x, lightVector.y, lightVector.z)];

            if (self.needsSpecular)
            {
                GLKVector4 lightSpecularColor = GLKVector4MultiplyScalar(light.specularColor.glkVector4, light.specularIntensity);

                NSString *lightSpecularColorLabel = [NSString stringWithFormat:@"u_lightSpecularColor%lu", (unsigned long)lightIndex];
                passInputs.shaderUniforms[weakSelf.uniformTranslationTable[lightSpecularColorLabel]] = [NSValue valueWithGLKVector4:lightSpecularColor];
            }
        }

        CCColor *ambientColor = [passInputs.sprite.scene.lights findAmbientSumForLightsWithMask:self.groupMask];
        passInputs.shaderUniforms[weakSelf.uniformTranslationTable[@"u_globalAmbientColor"]] = [NSValue valueWithGLKVector4:ambientColor.glkVector4];
        
        if (self.needsSpecular)
        {
            passInputs.shaderUniforms[weakSelf.uniformTranslationTable[@"u_specularExponent"]] = weakSelf.interface.conditionedShininess;
            passInputs.shaderUniforms[weakSelf.uniformTranslationTable[@"u_specularColor"]] = [NSValue valueWithGLKVector4:weakSelf.interface.specularColor.glkVector4];
        }
        
    } copy]];
    
    self.renderPasses = @[pass0];
}

- (CCEffectPrepareResult)prepareForRenderingWithSprite:(CCSprite *)sprite
{
    CCEffectPrepareResult result = CCEffectPrepareNoop;

    BOOL needsNormalMap = (sprite.normalMapSpriteFrame != nil);
    
    CGAffineTransform spriteTransform = sprite.nodeToWorldTransform;
    CGPoint spritePosition = CGPointApplyAffineTransform(sprite.anchorPointInPoints, sprite.nodeToWorldTransform);
    
    CCLightCollection *lightCollection = sprite.scene.lights;
    if (self.groupMaskDirty)
    {
        self.groupMask = [lightCollection maskForGroups:self.interface.groups];
        self.groupMaskDirty = NO;
    }
    
    self.closestLights = [lightCollection findClosestKLights:CCEffectLightingMaxLightCount toPoint:spritePosition withMask:self.groupMask];
    CCLightKey newLightKey = CCLightKeyMake(self.closestLights);
    
    if (!self.shader ||
        !CCLightKeyCompare(newLightKey, _lightKey) ||
        (_shaderHasSpecular != self.needsSpecular) ||
        (_shaderHasNormalMap != needsNormalMap))
    {
        _lightKey = newLightKey;
        _shaderHasSpecular = self.needsSpecular;
        _shaderHasNormalMap = needsNormalMap;
        
        NSMutableArray *fragUniforms = [[NSMutableArray alloc] initWithArray:@[
                                                                               [CCEffectUniform uniform:@"vec4" name:@"u_globalAmbientColor" value:[NSValue valueWithGLKVector4:GLKVector4Make(1.0f, 1.0f, 1.0f, 1.0f)]],
                                                                               [CCEffectUniform uniform:@"vec2" name:@"u_worldSpaceTangent" value:[NSValue valueWithGLKVector2:GLKVector2Make(1.0f, 0.0f)]],
                                                                               [CCEffectUniform uniform:@"vec2" name:@"u_worldSpaceBinormal" value:[NSValue valueWithGLKVector2:GLKVector2Make(0.0f, 1.0f)]]
                                                                               ]];
        NSMutableArray *vertUniforms = [[NSMutableArray alloc] initWithArray:@[
                                                                               [CCEffectUniform uniform:@"mat4" name:@"u_ndcToWorld" value:[NSValue valueWithGLKMatrix4:GLKMatrix4Identity]]
                                                                               ]];
        NSMutableArray *varyings = [[NSMutableArray alloc] init];
        
        for (NSUInteger lightIndex = 0; lightIndex < self.closestLights.count; lightIndex++)
        {
            CCLightNode *light = self.closestLights[lightIndex];
            
            [vertUniforms addObject:[CCEffectUniform uniform:@"vec3" name:[NSString stringWithFormat:@"u_lightVector%lu", (unsigned long)lightIndex] value:[NSValue valueWithGLKVector3:GLKVector3Make(0.0f, 0.0f, 0.0f)]]];
            [fragUniforms addObject:[CCEffectUniform uniform:@"vec4" name:[NSString stringWithFormat:@"u_lightColor%lu", (unsigned long)lightIndex] value:[NSValue valueWithGLKVector4:GLKVector4Make(1.0f, 1.0f, 1.0f, 1.0f)]]];
            if (self.needsSpecular)
            {
                [fragUniforms addObject:[CCEffectUniform uniform:@"vec4" name:[NSString stringWithFormat:@"u_lightSpecularColor%lu", (unsigned long)lightIndex] value:[NSValue valueWithGLKVector4:GLKVector4Make(1.0f, 1.0f, 1.0f, 1.0f)]]];
            }
            
            if (light.type != CCLightDirectional)
            {
                [fragUniforms addObject:[CCEffectUniform uniform:@"vec4" name:[NSString stringWithFormat:@"u_lightFalloff%lu", (unsigned long)lightIndex] value:[NSValue valueWithGLKVector4:GLKVector4Make(-1.0f, 1.0f, -1.0f, 1.0f)]]];
            }
            
            [varyings addObject:[CCEffectVarying varying:@"highp vec3" name:[NSString stringWithFormat:@"v_worldSpaceLightDir%lu", (unsigned long)lightIndex]]];
        }
        
        if (self.needsSpecular)
        {
            [fragUniforms addObject:[CCEffectUniform uniform:@"float" name:@"u_specularExponent" value:[NSNumber numberWithFloat:5.0f]]];
            [fragUniforms addObject:[CCEffectUniform uniform:@"vec4" name:@"u_specularColor" value:[NSValue valueWithGLKVector4:GLKVector4Make(1.0f, 1.0f, 1.0f, 1.0f)]]];
        }
        
        NSMutableArray *fragFunctions = [CCEffectLightingImpl buildFragmentFunctionsWithLights:self.closestLights normalMap:needsNormalMap specular:self.needsSpecular];
        NSMutableArray *vertFunctions = [CCEffectLightingImpl buildVertexFunctionsWithLights:self.closestLights];
        
        [self buildEffectWithFragmentFunction:fragFunctions vertexFunctions:vertFunctions fragmentUniforms:fragUniforms vertexUniforms:vertUniforms varyings:varyings firstInStack:YES];
        
        result.status = CCEffectPrepareSuccess;
        result.changes = CCEffectPrepareShaderChanged | CCEffectPrepareUniformsChanged;
    }
    return result;
}

- (BOOL)needsSpecular
{
    return (!ccc4FEqual(self.interface.specularColor.ccColor4f, ccc4f(0.0f, 0.0f, 0.0f, 0.0f)) && (self.interface.shininess > 0.0f));
}

@end


@implementation CCEffectLighting

-(id)init
{
    return [self initWithGroups:@[] specularColor:[CCColor whiteColor] shininess:0.5f];
}

-(id)initWithGroups:(NSArray *)groups specularColor:(CCColor *)specularColor shininess:(float)shininess
{
    if((self = [super init]))
    {
        self.effectImpl = [[CCEffectLightingImpl alloc] initWithInterface:self];
        self.debugName = @"CCEffectLighting";
        
        _groups = [groups copy];
        _specularColor = specularColor;
        _shininess = shininess;
        _conditionedShininess = [NSNumber numberWithFloat:conditionShininess(shininess)];
    }
    return self;
}


+(id)effectWithGroups:(NSArray *)groups specularColor:(CCColor *)specularColor shininess:(float)shininess
{
    return [[self alloc] initWithGroups:groups specularColor:specularColor shininess:shininess];
}

-(void)setGroups:(NSArray *)groups
{
    _groups = [groups copy];

    CCEffectLightingImpl *lightingImpl = (CCEffectLightingImpl *)self.effectImpl;
    lightingImpl.groupMaskDirty = YES;
}

-(void)setShininess:(float)shininess
{
    _shininess = shininess;
    _conditionedShininess = [NSNumber numberWithFloat:conditionShininess(shininess)];
}

@end


CCLightKey CCLightKeyMake(NSArray *lights)
{
    CCLightKey lightKey;
    lightKey.pointLightMask = 0;
    lightKey.directionalLightMask = 0;
    
    for (NSUInteger lightIndex = 0; lightIndex < lights.count; lightIndex++)
    {
        CCLightNode *light = lights[lightIndex];
        if (light.type == CCLightPoint)
        {
            lightKey.pointLightMask |= (1 << lightIndex);
        }
        else if (light.type == CCLightDirectional)
        {
            lightKey.directionalLightMask |= (1 << lightIndex);
        }
    }
    return lightKey;
}

BOOL CCLightKeyCompare(CCLightKey a, CCLightKey b)
{
    return (((a.pointLightMask) == (b.pointLightMask)) &&
            ((a.directionalLightMask) == (b.directionalLightMask)));
}

float conditionShininess(float shininess)
{
    // Map supplied shininess from [0..1] to [1..100]
    NSCAssert((shininess >= 0.0f) && (shininess <= 1.0f), @"Supplied shininess out of range [0..1].");
    shininess = clampf(shininess, 0.0f, 1.0f);
    return ((shininess * 99.0f) + 1.0f);
}

